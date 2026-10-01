#include "network.h"

#include <DNSServer.h>
#include <ESPmDNS.h>
#include <Preferences.h>
#include <WiFi.h>

#include "device.h"

namespace {

const char* const TAG = "net";
constexpr uint32_t kFirstConnectMs = 30000;  // without a connection by then: open the portal
constexpr uint32_t kLostMs = 180000;         // connection lost this long: open the portal
constexpr uint32_t kRetryMs = 20000;         // STA reconnect attempts, also while the portal is open

DNSServer dns;
String ssid, password;
bool portal = false;
bool mdnsStarted = false;
bool wasConnected = false;
uint32_t disconnectedSince = 0;
uint32_t lastAttempt = 0;

void setPortalFlag(bool on) {
  Lock lock;
  dev.portal = on;
}

void openPortal() {
  if (portal) return;
  char name[24];
  snprintf(name, sizeof name, "Pixelvisor-%s", dev.id);
  WiFi.mode(ssid.length() ? WIFI_AP_STA : WIFI_AP);
  WiFi.softAP(name);
  dns.start(53, "*", WiFi.softAPIP());  // every name resolves to the device: captive portal
  portal = true;
  setPortalFlag(true);
  ESP_LOGW(TAG, "Setup portal open: join \"%s\", then open http://%s", name, WiFi.softAPIP().toString().c_str());
}

void closePortal() {
  if (!portal) return;
  dns.stop();
  WiFi.softAPdisconnect(true);
  WiFi.mode(WIFI_STA);
  portal = false;
  setPortalFlag(false);
  ESP_LOGI(TAG, "Setup portal closed");
}

void startMdns() {
  DeviceConfig c;
  {
    Lock lock;
    c = dev.config;
  }
  if (!MDNS.begin(dev.running.hostname)) {
    ESP_LOGW(TAG, "mDNS failed to start; use the IP address");
    return;
  }
  MDNS.setInstanceName(c.name);
  MDNS.addService("http", "tcp", 80);
  MDNS.addService("pixelvisor", "tcp", 80);
  MDNS.addServiceTxt("pixelvisor", "tcp", "id", static_cast<const char*>(dev.id));
  MDNS.addServiceTxt("pixelvisor", "tcp", "api", String(kApiVersion));
  MDNS.addServiceTxt("pixelvisor", "tcp", "fw", LB_FW_VERSION);
  MDNS.addServiceTxt("pixelvisor", "tcp", "leds", String(dev.running.ledCount));
  MDNS.addServiceTxt("pixelvisor", "tcp", "ddp", String(kDdpPort));
  mdnsStarted = true;
}

}  // namespace

void netBegin() {
  Preferences prefs;
  prefs.begin("wifi");
  ssid = prefs.getString("ssid");
  password = prefs.getString("pass");
  prefs.end();

  WiFi.setHostname(dev.running.hostname);  // before the interfaces start
  WiFi.setSleep(false);                    // modem sleep adds latency and drops realtime frames
  if (ssid.isEmpty()) {
    openPortal();
    return;
  }
  WiFi.mode(WIFI_STA);
  WiFi.setAutoReconnect(true);
  WiFi.begin(ssid.c_str(), password.c_str());
  lastAttempt = disconnectedSince = millis();
  ESP_LOGI(TAG, "Connecting to \"%s\"", ssid.c_str());
}

void netLoop() {
  if (portal) dns.processNextRequest();
  if (ssid.isEmpty()) return;

  const uint32_t now = millis();
  const bool connected = WiFi.status() == WL_CONNECTED;
  if (connected && !wasConnected) {
    if (!mdnsStarted) startMdns();
    closePortal();
    ESP_LOGI(TAG, "Connected: http://%s.local (%s, RSSI %d dBm)", dev.running.hostname,
             WiFi.localIP().toString().c_str(), WiFi.RSSI());
  } else if (!connected && wasConnected) {
    ESP_LOGW(TAG, "WiFi lost, reconnecting");
    disconnectedSince = lastAttempt = now;
  }
  wasConnected = connected;
  if (connected) return;

  const uint32_t limit = mdnsStarted ? kLostMs : kFirstConnectMs;
  if (!portal && now - disconnectedSince > limit) openPortal();
  // A reconnect attempt can move the radio off the portal's channel, so none while a phone
  // or laptop is on the setup network.
  if (now - lastAttempt > kRetryMs && !(portal && WiFi.softAPgetStationNum() > 0)) {
    WiFi.begin(ssid.c_str(), password.c_str());
    lastAttempt = now;
  }
}

bool netPortalActive() { return portal; }

void netSave(const char* newSsid, const char* newPassword) {
  Preferences prefs;
  prefs.begin("wifi");
  prefs.putString("ssid", newSsid);
  prefs.putString("pass", newPassword);
  prefs.end();
  ESP_LOGI(TAG, "Saved WiFi \"%s\"", newSsid);
}

void netForget() {
  Preferences prefs;
  prefs.begin("wifi");
  prefs.clear();
  prefs.end();
  ESP_LOGI(TAG, "Forgot WiFi credentials");
}

void netScan(JsonArray out) {
  const int n = WiFi.scanNetworks();
  for (int i = 0; i < n; i++) {
    const String name = WiFi.SSID(i);
    if (name.isEmpty()) continue;
    bool duplicate = false;
    for (JsonObject seen : out) duplicate |= name == seen["ssid"].as<const char*>();
    if (duplicate) continue;  // results come sorted by signal, so the first is the strongest
    JsonObject network = out.add<JsonObject>();
    network["ssid"] = name;
    network["rssi"] = WiFi.RSSI(i);
    network["secure"] = WiFi.encryptionType(i) != WIFI_AUTH_OPEN;
  }
  WiFi.scanDelete();
}
