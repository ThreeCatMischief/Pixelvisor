// Pixelvisor firmware: renders the light state to a WS2812B strip at a fixed rate and serves
// the device API (docs/protocol.md), HTTP on port 80 and DDP realtime frames on UDP 4048.
//
// Two tasks share `dev` under its mutex: the Arduino loop (WiFi, HTTP, persistence) and the
// render task (DDP input, composition, output). The render task never waits on the network.

#include <Arduino.h>
#include <Preferences.h>
#include <WiFi.h>
#include <WiFiUdp.h>
#include <esp_mac.h>

#include "api.h"
#include "device.h"
#include "network.h"
#include "output.h"
#include "realtime.h"
#include "render.h"

Device dev;

namespace {

const char* const TAG = "pixelvisor";
constexpr uint32_t kPersistDelayMs = 5000;

// Everything the render task owns for one strip.
struct Output {
  StripOutput out;
  Realtime realtime;
  Compositor compositor;
  Pipeline pipeline;
  Rgb16 overlayFrame[kMaxLeds];
  uint8_t pixels[kMaxLeds * 3];
};
Output outputs[kStrips];

WiFiUDP udp;
Preferences prefs;
uint8_t packet[1500];

// Strip 0 keeps the namespaces of the single-strip firmware, so its stored data survives.
String nsName(const char* base, int strip) { return strip ? String(base) + strip : String(base); }

String load(const String& ns) {
  prefs.begin(ns.c_str());
  const String json = prefs.getString("json");
  prefs.end();
  return json;
}

void store(const String& ns, const String& json) {
  prefs.begin(ns.c_str());
  prefs.putString("json", json);
  prefs.end();
}

void loadConfig(int i) {
  DeviceConfig c = defaultConfig(i);
  const String json = load(nsName("config", i));
  if (json.length()) {
    JsonDocument doc;
    ApiError err;
    if (deserializeJson(doc, json) || !patchConfig(doc.as<JsonVariantConst>(), c, err)) {
      ESP_LOGW(TAG, "Stored config %d rejected (%s), using defaults", i, err.message ? err.message : "not JSON");
      c = defaultConfig(i);
    }
  }
  dev.ch[i].config = c;
  dev.ch[i].running = c;
}

void loadState(int i) {
  Channel& ch = dev.ch[i];
  LightState s;
  uint32_t rev = 0;
  const String json = load(nsName("state", i));
  if (json.length()) {
    JsonDocument doc;
    ApiError err;
    StatePatchResult result;
    if (deserializeJson(doc, json) || !patchState(doc.as<JsonVariantConst>(), s, result, err)) {
      ESP_LOGW(TAG, "Stored state %d rejected (%s), using defaults", i, err.message ? err.message : "not JSON");
      s = LightState();
    } else {
      rev = doc["rev"] | 0u;  // kept across reboots, so clients can tell nobody changed the state
    }
  }
  const LightState stored = s;
  if (ch.config.powerOn == PowerOn::On) s.on = true;
  if (ch.config.powerOn == PowerOn::Off) s.on = false;
  ch.state = s;
  ch.rev = s != stored ? rev + 1 : rev;
}

// Writes each state 5 s after its last change, or at once when `now` is set.
void persistState(bool now) {
  for (int i = 0; i < kStrips; i++) {
    LightState s;
    uint32_t rev;
    {
      Lock lock;
      Channel& ch = dev.ch[i];
      if (!ch.stateDirty || (!now && millis() - ch.stateChangedAt < kPersistDelayMs)) continue;
      ch.stateDirty = false;
      s = ch.state;
      rev = ch.rev;
    }
    JsonDocument doc;
    writeState(doc.to<JsonObject>(), s, rev, nullptr);
    String json;
    serializeJson(doc, json);
    store(nsName("state", i), json);
  }
}

void renderTask(void*) {
  uint32_t totalLeds = 0;
  for (const Channel& c : dev.ch) totalLeds += c.running.enabled ? c.running.ledCount : 0;  // config applies after a reboot
  const TickType_t period = pdMS_TO_TICKS(totalLeds <= 200 ? 8 : 16);  // about 120 or 60 Hz
  TickType_t wake = xTaskGetTickCount();
  for (;;) {
    struct Snapshot {
      LightState s;
      DeviceConfig c;
      uint16_t transitionMs;
      Transition transition;
      bool endRealtime;
      Overlay overlay;
      uint32_t overlayStart;
      uint16_t progress;
    } snap[kStrips];
    bool portal;
    {
      Lock lock;
      portal = dev.portal;
      for (int i = 0; i < kStrips; i++) {
        Channel& ch = dev.ch[i];
        snap[i] = {ch.state,   ch.config,       ch.transitionMs, ch.transition,
                   ch.endRealtime, ch.overlay, ch.overlayStart, ch.progress};
        ch.endRealtime = false;
      }
    }
    const uint32_t now = millis();  // after the snapshot, so overlayStart is never later

    for (int i = 0; i < kStrips; i++) {
      if (snap[i].endRealtime) outputs[i].realtime.end(now);
    }
    while (udp.parsePacket() > 0) {
      const int len = udp.read(packet, sizeof packet);
      if (len <= 0) continue;
      for (int i = 0; i < kStrips; i++) {  // each strip keeps the packets addressed to it
        outputs[i].realtime.receive(static_cast<uint32_t>(udp.remoteIP()), packet, len, snap[i].s.on, now);
      }
    }
    bool live[kStrips];
    {
      Lock lock;
      for (int i = 0; i < kStrips; i++) {
        Channel& ch = dev.ch[i];
        live[i] = outputs[i].realtime.active(now);
        ch.realtimeActive = live[i] && !ch.endRealtime;  // a PATCH with mode may be pending
        ch.realtimeSource = live[i] ? outputs[i].realtime.source() : 0;
      }
    }

    for (int i = 0; i < kStrips; i++) {
      if (!dev.ch[i].running.enabled) continue;
      Output& o = outputs[i];
      const uint16_t n = dev.ch[i].running.ledCount;
      DeviceConfig c = snap[i].c;
      c.ledCount = n;
      o.pipeline.configure(c);
      o.compositor.render(snap[i].s, snap[i].transitionMs, snap[i].transition,
                          live[i] ? o.realtime.frame() : nullptr, now);
      if (renderOverlay(snap[i].overlay, now - snap[i].overlayStart, snap[i].progress, o.overlayFrame, n)) {
        o.pipeline.processLinear(o.overlayFrame, o.pixels);
      } else {
        o.pipeline.process(o.compositor.frame(), o.compositor.brightness(), o.pixels);
        // Setup portal open: the first three LEDs breathe blue over the normal output.
        if (portal && renderOverlay(Overlay::Setup, now, 0, o.overlayFrame, 3)) o.pipeline.overlayLeds(o.overlayFrame, 3, o.pixels);
      }
      o.out.show(o.pixels);
    }
    vTaskDelayUntil(&wake, period);
  }
}

}  // namespace

void saveConfig(int strip, const DeviceConfig& c) {
  JsonDocument doc;
  writeConfig(doc.to<JsonObject>(), c, false);
  String json;
  serializeJson(doc, json);
  store(nsName("config", strip), json);
}

void setup() {
  Serial.begin(115200);
  dev.mutex = xSemaphoreCreateMutex();

  uint8_t mac[6];
  esp_read_mac(mac, ESP_MAC_WIFI_STA);
  snprintf(dev.id, sizeof dev.id, "%02x%02x%02x", mac[3], mac[4], mac[5]);
  for (int i = 0; i < kStrips; i++) {
    loadConfig(i);
    loadState(i);
    const Channel& ch = dev.ch[i];
    ESP_LOGI(TAG, "Strip %d \"%s\": %s, %u LEDs on GPIO %u", i, ch.config.name,
             ch.running.enabled ? "enabled" : "disabled", ch.running.ledCount, ch.running.dataPin);
  }
  ESP_LOGI(TAG, "Pixelvisor %s, id %s", LB_FW_VERSION, dev.id);

  // The pipeline applies color_order itself, so the output sends its buffer as written.
  for (int i = 0; i < kStrips; i++) {
    const Channel& ch = dev.ch[i];
    if (!ch.running.enabled) continue;
    if (!outputs[i].out.begin(ch.running.dataPin, ch.running.ledCount)) {
      ESP_LOGE(TAG, "Strip %d: output on GPIO %u failed to start", i, ch.running.dataPin);
    }
    outputs[i].realtime.begin(ch.running.ledCount, i + 1);  // DDP output ID = strip index + 1
    outputs[i].compositor.begin(ch.running.ledCount, ch.state, millis());
  }
  xTaskCreate(renderTask, "render", 6144, nullptr, 5, nullptr);

  netBegin();
  udp.begin(kDdpPort);
  apiBegin();
}

void loop() {
  netLoop();
  apiLoop();  // waits about 1 ms when idle
  persistState(false);

  uint32_t restartAt;
  {
    Lock lock;
    restartAt = dev.restartAt;
  }
  if (restartAt && static_cast<int32_t>(millis() - restartAt) >= 0) {
    persistState(true);
    ESP.restart();
  }
}
