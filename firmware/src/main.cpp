// Pixelvisor firmware: renders the light state to a WS2812B strip at a fixed rate and serves
// the device API (docs/protocol.md), HTTP on port 80 and DDP realtime frames on UDP 4048.
//
// Two tasks share `dev` under its mutex: the Arduino loop (WiFi, HTTP, persistence) and the
// render task (DDP input, composition, output). The render task never waits on the network.

#include <Adafruit_NeoPixel.h>
#include <Arduino.h>
#include <Preferences.h>
#include <WiFi.h>
#include <WiFiUdp.h>
#include <esp_mac.h>

#include "api.h"
#include "device.h"
#include "network.h"
#include "realtime.h"
#include "render.h"

Device dev;

namespace {

const char* const TAG = "pixelvisor";
constexpr uint32_t kPersistDelayMs = 5000;

// Count and pin are set in setup(). The constructor with arguments is required: only it
// creates the ESP32 show mutex, and without that mutex show() silently does nothing.
Adafruit_NeoPixel strip(0, -1, NEO_RGB + NEO_KHZ800);
WiFiUDP udp;
Preferences prefs;

// Owned by the render task.
Realtime realtime;
Compositor compositor;
Pipeline pipeline;
Rgb16 overlayFrame[kMaxLeds];
uint8_t packet[1500];

String load(const char* ns) {
  prefs.begin(ns);
  const String json = prefs.getString("json");
  prefs.end();
  return json;
}

void store(const char* ns, const String& json) {
  prefs.begin(ns);
  prefs.putString("json", json);
  prefs.end();
}

void loadConfig() {
  DeviceConfig c;
  const String json = load("config");
  if (json.length()) {
    JsonDocument doc;
    ApiError err;
    if (deserializeJson(doc, json) || !patchConfig(doc.as<JsonVariantConst>(), c, err)) {
      ESP_LOGW(TAG, "Stored config rejected (%s), using defaults", err.message ? err.message : "not JSON");
      c = DeviceConfig();
    }
  }
  dev.config = c;
  dev.running = c;
}

void loadState() {
  LightState s;
  uint32_t rev = 0;
  const String json = load("state");
  if (json.length()) {
    JsonDocument doc;
    ApiError err;
    StatePatchResult result;
    if (deserializeJson(doc, json) || !patchState(doc.as<JsonVariantConst>(), s, result, err)) {
      ESP_LOGW(TAG, "Stored state rejected (%s), using defaults", err.message ? err.message : "not JSON");
      s = LightState();
    } else {
      rev = doc["rev"] | 0u;  // kept across reboots, so clients can tell nobody changed the state
    }
  }
  const LightState stored = s;
  if (dev.config.powerOn == PowerOn::On) s.on = true;
  if (dev.config.powerOn == PowerOn::Off) s.on = false;
  dev.state = s;
  dev.rev = s != stored ? rev + 1 : rev;
}

// Writes the state 5 s after the last change, or at once when `now` is set.
void persistState(bool now) {
  LightState s;
  uint32_t rev;
  {
    Lock lock;
    if (!dev.stateDirty || (!now && millis() - dev.stateChangedAt < kPersistDelayMs)) return;
    dev.stateDirty = false;
    s = dev.state;
    rev = dev.rev;
  }
  JsonDocument doc;
  writeState(doc.to<JsonObject>(), s, rev, nullptr);
  String json;
  serializeJson(doc, json);
  store("state", json);
}

void renderTask(void*) {
  const uint16_t n = dev.running.ledCount;  // led_count and data_pin apply after a reboot
  const TickType_t period = pdMS_TO_TICKS(n <= 200 ? 8 : 16);  // about 120 or 60 Hz
  TickType_t wake = xTaskGetTickCount();
  for (;;) {
    LightState s;
    DeviceConfig c;
    uint16_t transitionMs;
    bool endRealtime;
    Overlay overlay;
    uint32_t overlayStart;
    uint16_t progress;
    bool portal;
    {
      Lock lock;
      s = dev.state;
      c = dev.config;
      transitionMs = dev.transitionMs;
      endRealtime = dev.endRealtime;
      dev.endRealtime = false;
      overlay = dev.overlay;
      overlayStart = dev.overlayStart;
      progress = dev.progress;
      portal = dev.portal;
    }
    const uint32_t now = millis();  // after the snapshot, so overlayStart is never later

    if (endRealtime) realtime.end(now);
    while (udp.parsePacket() > 0) {
      const int len = udp.read(packet, sizeof packet);
      if (len > 0) realtime.receive(static_cast<uint32_t>(udp.remoteIP()), packet, len, s.on, now);
    }
    const bool live = realtime.active(now);
    {
      Lock lock;
      dev.realtimeActive = live && !dev.endRealtime;  // a PATCH with mode may be pending
      dev.realtimeSource = live ? realtime.source() : 0;
    }

    c.ledCount = n;
    pipeline.configure(c);
    compositor.render(s, transitionMs, live ? realtime.frame() : nullptr, now);
    uint8_t* out = strip.getPixels();
    if (renderOverlay(overlay, now - overlayStart, progress, overlayFrame, n)) {
      pipeline.processLinear(overlayFrame, out);
    } else {
      pipeline.process(compositor.frame(), compositor.brightness(), out);
      // Setup portal open: the first three LEDs breathe blue over the normal output.
      if (portal && renderOverlay(Overlay::Setup, now, 0, overlayFrame, 3)) pipeline.overlayLeds(overlayFrame, 3, out);
    }
    strip.show();
    vTaskDelayUntil(&wake, period);
  }
}

}  // namespace

void saveConfig(const DeviceConfig& c) {
  JsonDocument doc;
  writeConfig(doc.to<JsonObject>(), c, false);
  String json;
  serializeJson(doc, json);
  store("config", json);
}

void setup() {
  Serial.begin(115200);
  dev.mutex = xSemaphoreCreateMutex();

  uint8_t mac[6];
  esp_read_mac(mac, ESP_MAC_WIFI_STA);
  snprintf(dev.id, sizeof dev.id, "%02x%02x%02x", mac[3], mac[4], mac[5]);
  loadConfig();
  loadState();
  ESP_LOGI(TAG, "Pixelvisor %s, id %s, %u LEDs on GPIO %u", LB_FW_VERSION, dev.id, dev.running.ledCount,
           dev.running.dataPin);

  // NEO_RGB sends the buffer as written; the pipeline applies color_order itself.
  strip.updateType(NEO_RGB + NEO_KHZ800);
  strip.updateLength(dev.running.ledCount);
  strip.setPin(dev.running.dataPin);
  strip.begin();
  realtime.begin(dev.running.ledCount);
  compositor.begin(dev.running.ledCount, dev.state, millis());
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
