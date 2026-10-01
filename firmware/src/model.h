// Light state, device configuration and their JSON form (docs/protocol.md). No Arduino
// dependencies, so the validation rules run in the native tests.
#pragma once

#include <ArduinoJson.h>
#include <stdint.h>

// Compile-time defaults, each settable from platformio.ini.
#ifndef LB_FW_VERSION
#define LB_FW_VERSION "0.1.0"
#endif
#ifndef LB_DEFAULT_HOSTNAME
#define LB_DEFAULT_HOSTNAME "pixelvisor"
#endif
#ifndef LB_DEFAULT_NAME
#define LB_DEFAULT_NAME "Pixelvisor"
#endif
#ifndef LB_DEFAULT_LED_COUNT
#define LB_DEFAULT_LED_COUNT 43
#endif
#ifndef LB_DEFAULT_DATA_PIN
#define LB_DEFAULT_DATA_PIN 4
#endif
#ifndef LB_DEFAULT_MAX_CURRENT_MA
#define LB_DEFAULT_MAX_CURRENT_MA 1500
#endif
// GPIOs accepted as data_pin. ESP32-C3: no strapping pins (2, 8, 9), flash pins (11-17),
// USB pins (18, 19), or U0TXD (21), which carries the boot log.
#ifndef LB_DATA_PINS
#define LB_DATA_PINS 0, 1, 3, 4, 5, 6, 7, 10, 20
#endif

constexpr int kApiVersion = 1;
constexpr uint16_t kMaxLeds = 480;  // DDP single-packet limit
constexpr uint16_t kDdpPort = 4048;

struct Rgb {
  uint8_t r, g, b;
};
inline bool operator==(const Rgb& a, const Rgb& b) { return a.r == b.r && a.g == b.g && a.b == b.b; }
inline bool operator!=(const Rgb& a, const Rgb& b) { return !(a == b); }

// One LED at 16 bit per channel, from the source frame to the output pipeline.
struct Rgb16 {
  uint16_t r, g, b;
};

enum class Mode : uint8_t { Solid, Effect };

struct LightState {
  bool on = true;
  uint8_t brightness = 128;
  Mode mode = Mode::Solid;
  Rgb color = {255, 170, 90};
  uint8_t effect = 0;  // index into kEffects
  uint8_t speed = 128;
  Rgb color2 = {0, 0, 0};
};
bool operator==(const LightState& a, const LightState& b);
inline bool operator!=(const LightState& a, const LightState& b) { return !(a == b); }

enum class PowerOn : uint8_t { Restore, On, Off };

struct DeviceConfig {
  char name[64] = LB_DEFAULT_NAME;  // 1-32 characters, UTF-8
  char hostname[25] = LB_DEFAULT_HOSTNAME;
  uint16_t ledCount = LB_DEFAULT_LED_COUNT;
  uint8_t dataPin = LB_DEFAULT_DATA_PIN;
  uint8_t colorOrder = 2;  // index into kColorOrders: GRB
  bool reverse = false;
  uint16_t maxCurrentMa = LB_DEFAULT_MAX_CURRENT_MA;
  uint8_t maPerChannel = 20;
  Rgb whiteBalance = {255, 224, 200};
  float gamma = 2.2f;
  bool dither = true;
  PowerOn powerOn = PowerOn::Restore;
};

inline constexpr const char* kColorOrders[] = {"RGB", "RBG", "GRB", "GBR", "BRG", "BGR"};

// Validation failure, sent as {"error": message, "field": field}.
struct ApiError {
  const char* message = nullptr;
  const char* field = nullptr;
};

struct StatePatchResult {
  bool changed = false;  // a stored field has a new value
  bool hasMode = false;  // the patch contains `mode`, which ends realtime
  uint16_t transitionMs = 400;
};

// Applies a PATCH /api/state body. All-or-nothing: on failure `state` is unchanged.
bool patchState(JsonVariantConst body, LightState& state, StatePatchResult& result, ApiError& err);
// GET /api/state body. `realtimeSource` is the sender IP, or null when no stream is active.
void writeState(JsonObject out, const LightState& s, uint32_t rev, const char* realtimeSource);

// Applies a PATCH /api/config body. All-or-nothing.
bool patchConfig(JsonVariantConst body, DeviceConfig& config, ApiError& err);
void writeConfig(JsonObject out, const DeviceConfig& c, bool rebootRequired);
// True when a field that applies only after a reboot differs.
bool rebootRequired(const DeviceConfig& stored, const DeviceConfig& running);
bool dataPinAllowed(int pin);
