#include "model.h"

#include <math.h>
#include <string.h>

#include "effects.h"

namespace {

const char* const kModes[] = {"solid", "effect"};
const char* const kPowerOn[] = {"restore", "on", "off"};
const uint8_t kDataPins[] = {LB_DATA_PINS};

bool fail(ApiError& err, const char* message, const char* field) {
  err.message = message;
  err.field = field;
  return false;
}

bool readInt(JsonVariantConst v, int lo, int hi, int& out) {
  if (!v.is<int>()) return false;
  const int n = v.as<int>();
  if (n < lo || n > hi) return false;
  out = n;
  return true;
}

bool readByte(JsonVariantConst v, uint8_t& out) {
  int n;
  if (!readInt(v, 0, 255, n)) return false;
  out = static_cast<uint8_t>(n);
  return true;
}

bool readRgb(JsonVariantConst v, Rgb& out) {
  JsonArrayConst a = v.as<JsonArrayConst>();
  Rgb c;
  if (a.isNull() || a.size() != 3 || !readByte(a[0], c.r) || !readByte(a[1], c.g) ||
      !readByte(a[2], c.b)) {
    return false;
  }
  out = c;
  return true;
}

void addRgb(JsonArray a, const Rgb& c) {
  a.add(c.r);
  a.add(c.g);
  a.add(c.b);
}

// Index of `s` in `list`, or -1.
template <size_t N>
int indexOf(const char* const (&list)[N], const char* s) {
  if (!s) return -1;
  for (size_t i = 0; i < N; i++) {
    if (!strcmp(list[i], s)) return static_cast<int>(i);
  }
  return -1;
}

size_t utf8Length(const char* s) {
  size_t n = 0;
  for (; *s; s++) n += (*s & 0xC0) != 0x80;
  return n;
}

bool validHostname(const char* s) {
  const size_t n = strlen(s);
  if (n < 1 || n > 24) return false;
  for (size_t i = 0; i < n; i++) {
    const char c = s[i];
    if (!((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-')) return false;
  }
  return true;
}

}  // namespace

bool operator==(const LightState& a, const LightState& b) {
  return a.on == b.on && a.brightness == b.brightness && a.mode == b.mode && a.color == b.color &&
         a.effect == b.effect && a.speed == b.speed && a.color2 == b.color2;
}

bool patchState(JsonVariantConst body, LightState& state, StatePatchResult& result, ApiError& err) {
  if (!body.is<JsonObjectConst>()) return fail(err, "body must be a JSON object", nullptr);
  LightState s = state;
  StatePatchResult r;
  JsonVariantConst v;

  if (!(v = body["on"]).isNull()) {
    if (!v.is<bool>()) return fail(err, "on must be true or false", "on");
    s.on = v.as<bool>();
  }
  if (!(v = body["brightness"]).isNull() && !readByte(v, s.brightness)) {
    return fail(err, "brightness must be an integer 0-255", "brightness");
  }
  if (!(v = body["mode"]).isNull()) {
    const int m = indexOf(kModes, v.as<const char*>());
    if (m < 0) return fail(err, "mode must be \"solid\" or \"effect\"", "mode");
    s.mode = static_cast<Mode>(m);
    r.hasMode = true;
  }
  if (!(v = body["color"]).isNull() && !readRgb(v, s.color)) {
    return fail(err, "color must be [r, g, b] with integers 0-255", "color");
  }
  JsonVariantConst effect = body["effect"];
  if (!effect.isNull()) {
    if (!effect.is<JsonObjectConst>()) return fail(err, "effect must be an object", "effect");
    if (!(v = effect["id"]).isNull()) {
      const int id = findEffect(v.as<const char*>());
      if (id < 0) return fail(err, "unknown effect id, see GET /api/effects", "effect.id");
      s.effect = static_cast<uint8_t>(id);
    }
    if (!(v = effect["speed"]).isNull() && !readByte(v, s.speed)) {
      return fail(err, "effect.speed must be an integer 0-255", "effect.speed");
    }
    if (!(v = effect["color2"]).isNull() && !readRgb(v, s.color2)) {
      return fail(err, "effect.color2 must be [r, g, b] with integers 0-255", "effect.color2");
    }
  }
  if (!(v = body["transition_ms"]).isNull()) {
    int ms;
    if (!readInt(v, 0, 10000, ms)) {
      return fail(err, "transition_ms must be an integer 0-10000", "transition_ms");
    }
    r.transitionMs = static_cast<uint16_t>(ms);
  }

  r.changed = s != state;
  state = s;
  result = r;
  return true;
}

void writeState(JsonObject out, const LightState& s, uint32_t rev, const char* realtimeSource) {
  out["rev"] = rev;
  out["on"] = s.on;
  out["brightness"] = s.brightness;
  out["mode"] = kModes[static_cast<int>(s.mode)];
  addRgb(out["color"].to<JsonArray>(), s.color);
  JsonObject effect = out["effect"].to<JsonObject>();
  effect["id"] = kEffects[s.effect].id;
  effect["speed"] = s.speed;
  addRgb(effect["color2"].to<JsonArray>(), s.color2);
  JsonObject realtime = out["realtime"].to<JsonObject>();
  realtime["active"] = realtimeSource != nullptr;
  realtime["source"] = realtimeSource;
}

bool patchConfig(JsonVariantConst body, DeviceConfig& config, ApiError& err) {
  if (!body.is<JsonObjectConst>()) return fail(err, "body must be a JSON object", nullptr);
  DeviceConfig c = config;
  JsonVariantConst v;
  int n;

  if (!(v = body["name"]).isNull()) {
    const char* s = v.as<const char*>();
    const size_t length = s ? utf8Length(s) : 0;
    if (length < 1 || length > 32 || strlen(s) >= sizeof c.name) {
      return fail(err, "name must be 1-32 characters", "name");
    }
    strcpy(c.name, s);
  }
  if (!(v = body["hostname"]).isNull()) {
    const char* s = v.as<const char*>();
    if (!s || !validHostname(s)) return fail(err, "hostname must match [a-z0-9-]{1,24}", "hostname");
    strcpy(c.hostname, s);
  }
  if (!(v = body["led_count"]).isNull()) {
    if (!readInt(v, 1, kMaxLeds, n)) return fail(err, "led_count must be an integer 1-480", "led_count");
    c.ledCount = static_cast<uint16_t>(n);
  }
  if (!(v = body["data_pin"]).isNull()) {
    if (!v.is<int>() || !dataPinAllowed(v.as<int>())) {
      return fail(err, "data_pin is not an allowed GPIO on this board", "data_pin");
    }
    c.dataPin = static_cast<uint8_t>(v.as<int>());
  }
  if (!(v = body["color_order"]).isNull()) {
    n = indexOf(kColorOrders, v.as<const char*>());
    if (n < 0) return fail(err, "color_order must be RGB, RBG, GRB, GBR, BRG or BGR", "color_order");
    c.colorOrder = static_cast<uint8_t>(n);
  }
  if (!(v = body["reverse"]).isNull()) {
    if (!v.is<bool>()) return fail(err, "reverse must be true or false", "reverse");
    c.reverse = v.as<bool>();
  }
  if (!(v = body["max_current_ma"]).isNull()) {
    if (!readInt(v, 0, 20000, n) || (n > 0 && n < 100)) {
      return fail(err, "max_current_ma must be 0 or 100-20000", "max_current_ma");
    }
    c.maxCurrentMa = static_cast<uint16_t>(n);
  }
  if (!(v = body["ma_per_channel"]).isNull()) {
    if (!readInt(v, 1, 60, n)) return fail(err, "ma_per_channel must be an integer 1-60", "ma_per_channel");
    c.maPerChannel = static_cast<uint8_t>(n);
  }
  if (!(v = body["white_balance"]).isNull() && !readRgb(v, c.whiteBalance)) {
    return fail(err, "white_balance must be [r, g, b] with integers 0-255", "white_balance");
  }
  if (!(v = body["gamma"]).isNull()) {
    if (!v.is<float>() || v.as<float>() < 1.0f || v.as<float>() > 3.0f) {
      return fail(err, "gamma must be a number 1.0-3.0", "gamma");
    }
    c.gamma = v.as<float>();
  }
  if (!(v = body["dither"]).isNull()) {
    if (!v.is<bool>()) return fail(err, "dither must be true or false", "dither");
    c.dither = v.as<bool>();
  }
  if (!(v = body["power_on"]).isNull()) {
    n = indexOf(kPowerOn, v.as<const char*>());
    if (n < 0) return fail(err, "power_on must be \"restore\", \"on\" or \"off\"", "power_on");
    c.powerOn = static_cast<PowerOn>(n);
  }

  config = c;
  return true;
}

void writeConfig(JsonObject out, const DeviceConfig& c, bool rebootRequired) {
  // ArduinoJson stores a const char[N] by pointer as a literal of length N-1; a const char* is copied.
  out["name"] = static_cast<const char*>(c.name);
  out["hostname"] = static_cast<const char*>(c.hostname);
  out["led_count"] = c.ledCount;
  out["data_pin"] = c.dataPin;
  out["color_order"] = kColorOrders[c.colorOrder];
  out["reverse"] = c.reverse;
  out["max_current_ma"] = c.maxCurrentMa;
  out["ma_per_channel"] = c.maPerChannel;
  addRgb(out["white_balance"].to<JsonArray>(), c.whiteBalance);
  out["gamma"] = round(c.gamma * 100.0) / 100.0;  // 2.2, not 2.2000000477
  out["dither"] = c.dither;
  out["power_on"] = kPowerOn[static_cast<int>(c.powerOn)];
  out["reboot_required"] = rebootRequired;
}

bool rebootRequired(const DeviceConfig& stored, const DeviceConfig& running) {
  return strcmp(stored.hostname, running.hostname) != 0 || stored.ledCount != running.ledCount ||
         stored.dataPin != running.dataPin;
}

bool dataPinAllowed(int pin) {
  for (uint8_t p : kDataPins) {
    if (p == pin) return true;
  }
  return false;
}
