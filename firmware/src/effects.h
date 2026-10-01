// Effects for mode "effect" (docs/firmware-spec.md, Effects). Pure functions of the state
// and the animation phase, so their output is testable on the host.
#pragma once

#include "model.h"

enum : uint8_t { kUsesColor = 1, kUsesColor2 = 2, kUsesSpeed = 4 };

struct EffectInfo {
  const char* id;
  const char* name;
  uint8_t uses;
};

extern const EffectInfo kEffects[];
extern const uint8_t kEffectCount;

// Index into kEffects, or -1.
int findEffect(const char* id);
// Duration of one animation cycle at `speed`, or 0 for a static effect.
uint32_t effectPeriodMs(uint8_t effect, uint8_t speed);
// Writes `n` LEDs in sRGB, 16 bit per channel. `phase` is the position in the cycle, 0-65535.
void renderEffect(const LightState& s, uint16_t phase, Rgb16* out, uint16_t n);
// GET /api/effects body.
void writeEffects(JsonArray out);

// sRGB <-> linear light (exponent 2.2), for blending colors.
uint16_t srgbToLinear(uint8_t c);
uint16_t linearToSrgb16(uint16_t linear);

// Linear interpolation: w = 0 gives a, w = 65535 gives b. A 15-bit weight keeps it in int32.
inline uint16_t mix16(uint16_t a, uint16_t b, uint16_t w) {
  return static_cast<uint16_t>(a + (static_cast<int32_t>(b) - a) * (w >> 1) / 32767);
}

// Smoothstep easing on 0-65535.
inline uint16_t smoothstep16(uint16_t x) {
  const uint32_t t2 = static_cast<uint32_t>(x) * x / 65535;
  const uint32_t t3 = t2 * x / 65535;
  const uint32_t y = 3 * t2 - 2 * t3;
  return static_cast<uint16_t>(y > 65535 ? 65535 : y);
}
