#include "api.h"

#include <ESPmDNS.h>
#include <Update.h>
#include <WebServer.h>
#include <WiFi.h>
#include <esp_timer.h>

#include "device.h"
#include "effects.h"
#include "network.h"
#include "page.h"

namespace {

WebServer server(80);

// Request bodies arrive through the raw handler, which accepts any content type. Without
// it, WebServer parses `curl -d` bodies (form encoded by default) as form fields.
char body[2048];
size_t bodyLength = 0;
bool bodyComplete = false;
bool bodyTooLarge = false;

// Firmware upload state, set by otaUpload() and reported by handleOta().
bool otaStarted = false;
size_t otaSize = 0;
int otaStatus = 0;
const char* otaError = nullptr;

void sendJson(int code, const JsonDocument& doc) {
  String out;
  serializeJson(doc, out);
  server.send(code, "application/json", out);
}

void sendError(int code, const char* message, const char* field = nullptr) {
  JsonDocument doc;
  doc["error"] = message;
  if (field) doc["field"] = field;
  sendJson(code, doc);
}

void sendOk(int code) {
  JsonDocument doc;
  doc["ok"] = true;
  sendJson(code, doc);
}

void collectBody() {
  const HTTPRaw& raw = server.raw();
  switch (raw.status) {
    case RAW_START:
      bodyLength = 0;
      bodyComplete = false;
      bodyTooLarge = false;
      break;
    case RAW_WRITE:
      if (bodyLength + raw.currentSize >= sizeof body) {
        bodyTooLarge = true;
      } else {
        memcpy(body + bodyLength, raw.buf, raw.currentSize);
        bodyLength += raw.currentSize;
      }
      break;
    case RAW_END:
      bodyComplete = true;
      break;
    case RAW_ABORTED:
      break;
  }
}

// Parses the collected body. Sends the error response and returns false if it is unusable.
bool readBody(JsonDocument& doc) {
  const bool complete = bodyComplete;
  bodyComplete = false;
  if (!complete || bodyLength == 0) {
    sendError(400, "expected a JSON body");
    return false;
  }
  if (bodyTooLarge) {
    sendError(400, "body larger than 2 KB");
    return false;
  }
  if (deserializeJson(doc, body, bodyLength)) {
    sendError(400, "body is not valid JSON");
    return false;
  }
  return true;
}

void sendState() {
  LightState s;
  uint32_t rev;
  uint32_t source = 0;
  {
    Lock lock;
    s = dev.state;
    rev = dev.rev;
    if (dev.realtimeActive) source = dev.realtimeSource;
  }
  const String ip = source ? IPAddress(source).toString() : String();
  JsonDocument doc;
  writeState(doc.to<JsonObject>(), s, rev, source ? ip.c_str() : nullptr);
  sendJson(200, doc);
}

void sendConfig() {
  DeviceConfig c;
  {
    Lock lock;
    c = dev.config;
  }
  JsonDocument doc;
  writeConfig(doc.to<JsonObject>(), c, rebootRequired(c, dev.running));
  sendJson(200, doc);
}

void handleRoot() { server.send(200, "text/html", netPortalActive() ? kSetupPage : kPage); }

void handleInfo() {
  DeviceConfig c;
  {
    Lock lock;
    c = dev.config;
  }
  JsonDocument doc;
  doc["api"] = kApiVersion;
  doc["fw"] = LB_FW_VERSION;
  doc["id"] = dev.id;
  doc["name"] = c.name;
  doc["hostname"] = dev.running.hostname;
  doc["board"] = CONFIG_IDF_TARGET;
  doc["led_count"] = dev.running.ledCount;
  doc["ip"] = WiFi.localIP().toString();
  doc["rssi"] = WiFi.RSSI();
  doc["uptime_s"] = static_cast<uint32_t>(esp_timer_get_time() / 1000000);
  doc["free_heap"] = ESP.getFreeHeap();
  JsonObject ddp = doc["ddp"].to<JsonObject>();
  ddp["port"] = kDdpPort;
  ddp["max_leds"] = kMaxLeds;
  sendJson(200, doc);
}

void handlePatchState() {
  JsonDocument doc;
  if (!readBody(doc)) return;
  ApiError err;
  StatePatchResult result;
  bool ok;
  {
    Lock lock;
    ok = patchState(doc.as<JsonVariantConst>(), dev.state, result, err);
    if (ok) {
      dev.transitionMs = result.transitionMs;
      if (result.changed) {
        dev.rev++;
        dev.stateDirty = true;
        dev.stateChangedAt = millis();
      }
      if (result.hasMode) {
        dev.endRealtime = true;
        dev.realtimeActive = false;
      }
    }
  }
  if (!ok) {
    sendError(400, err.message, err.field);
    return;
  }
  sendState();
}

void handleEffects() {
  JsonDocument doc;
  writeEffects(doc.to<JsonArray>());
  sendJson(200, doc);
}

void handlePatchConfig() {
  JsonDocument doc;
  if (!readBody(doc)) return;
  DeviceConfig c;
  {
    Lock lock;
    c = dev.config;
  }
  const DeviceConfig before = c;
  ApiError err;
  if (!patchConfig(doc.as<JsonVariantConst>(), c, err)) {
    sendError(400, err.message, err.field);
    return;
  }
  {
    Lock lock;
    dev.config = c;
  }
  saveConfig(c);
  if (strcmp(before.name, c.name) != 0) MDNS.setInstanceName(c.name);
  sendConfig();
}

void handleReboot() {
  sendOk(202);
  Lock lock;
  dev.restartAt = millis() + 500;
}

void handleIdentify() {
  showOverlay(Overlay::Identify);
  sendOk(202);
}

void restartSoon(uint32_t ms) {
  Lock lock;
  dev.restartAt = millis() + ms;
}

void handleScan() {
  JsonDocument doc;
  netScan(doc.to<JsonArray>());
  sendJson(200, doc);
}

// Stores new credentials and restarts to join that network.
void handleSetWifi() {
  JsonDocument doc;
  if (!readBody(doc)) return;
  const char* ssid = doc["ssid"];
  const char* password = doc["password"] | "";
  if (!ssid || strlen(ssid) < 1 || strlen(ssid) > 32) {
    sendError(400, "ssid must be 1-32 bytes", "ssid");
    return;
  }
  const size_t n = strlen(password);
  if (n != 0 && (n < 8 || n > 63)) {
    sendError(400, "password must be empty or 8-63 characters", "password");
    return;
  }
  netSave(ssid, password);
  sendOk(202);
  restartSoon(1000);
}

void handleForgetWifi() {
  netForget();
  sendOk(202);
  restartSoon(1000);
}

void otaFail(int status, const char* message) {
  otaStatus = status;
  otaError = message;
  showOverlay(Overlay::Failure);
}

void otaUpload() {
  const HTTPRaw& raw = server.raw();
  switch (raw.status) {
    case RAW_START: {
      otaStarted = true;
      otaError = nullptr;
      otaSize = server.clientContentLength();
      if (otaSize == 0) {
        otaFail(400, "expected the image with a Content-Length");
        return;
      }
      if (!Update.begin(otaSize)) {
        otaFail(400, Update.errorString());
        return;
      }
      const String md5 = server.header("X-Firmware-MD5");
      if (md5.length() && (md5.length() != 32 || !Update.setMD5(md5.c_str()))) {
        Update.abort();
        otaFail(400, "X-Firmware-MD5 must be 32 hex characters");
        return;
      }
      showOverlay(Overlay::Progress);
      break;
    }
    case RAW_WRITE:
      if (otaError) return;
      if (Update.write(const_cast<uint8_t*>(raw.buf), raw.currentSize) != raw.currentSize) {
        const bool badImage = Update.getError() == UPDATE_ERROR_MAGIC_BYTE;
        const char* message = Update.errorString();
        Update.abort();
        otaFail(badImage ? 400 : 500, message);
        return;
      }
      setProgress(static_cast<uint16_t>(static_cast<uint64_t>(raw.totalSize) * 1000 / otaSize));
      break;
    case RAW_END:
      if (otaError) return;
      if (!Update.end()) {
        const uint8_t e = Update.getError();
        otaFail(e == UPDATE_ERROR_MD5 || e == UPDATE_ERROR_MAGIC_BYTE ? 400 : 500, Update.errorString());
      }
      break;
    case RAW_ABORTED:  // WebServer drops the request; handleOta() does not run
      if (!otaError) {
        Update.abort();
        otaFail(400, "upload interrupted");
      }
      otaStarted = false;
      break;
  }
}

void handleOta() {
  const bool started = otaStarted;
  otaStarted = false;
  if (!started) {
    sendError(400, "send the image as the raw body (application/octet-stream)");
    return;
  }
  if (otaError) {
    sendError(otaStatus, otaError);
    return;
  }
  sendOk(200);
  showOverlay(Overlay::Success);
  Lock lock;
  dev.restartAt = millis() + 1000;
}

void handleNotFound() {
  if (server.method() == HTTP_OPTIONS) {
    server.send(204);  // CORS preflight; enableCORS adds the Allow headers
    return;
  }
  // Setup portal: phones and laptops probe a known URL after joining; anything but the
  // expected answer makes them show the setup page.
  if (netPortalActive() && !server.uri().startsWith("/api/")) {
    server.sendHeader("Location", "http://" + WiFi.softAPIP().toString() + "/");
    server.send(302, "text/plain", "");
    return;
  }
  sendError(404, "not found");
}

}  // namespace

void apiBegin() {
  server.on("/", HTTP_GET, handleRoot);
  server.on("/api/info", HTTP_GET, handleInfo);
  server.on("/api/state", HTTP_GET, sendState);
  server.on("/api/state", HTTP_PATCH, handlePatchState, collectBody);
  server.on("/api/effects", HTTP_GET, handleEffects);
  server.on("/api/config", HTTP_GET, sendConfig);
  server.on("/api/config", HTTP_PATCH, handlePatchConfig, collectBody);
  server.on("/api/reboot", HTTP_POST, handleReboot);
  server.on("/api/identify", HTTP_POST, handleIdentify);
  server.on("/api/wifi/scan", HTTP_GET, handleScan);
  server.on("/api/wifi", HTTP_POST, handleSetWifi, collectBody);
  server.on("/api/wifi", HTTP_DELETE, handleForgetWifi);
  server.on("/api/ota", HTTP_POST, handleOta, otaUpload);
  server.onNotFound(handleNotFound);
  server.enableCORS(true);
  const char* headers[] = {"X-Firmware-MD5"};
  server.collectHeaders(headers, 1);
  server.begin();
}

void apiLoop() { server.handleClient(); }
