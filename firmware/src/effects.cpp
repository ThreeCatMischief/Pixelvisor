#include "effects.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>

const EffectInfo kEffects[] = {
    {"breathe", "Breathe", kUsesColor | kUsesSpeed},
    {"rainbow", "Rainbow", kUsesSpeed},
    {"gradient", "Gradient", kUsesColor | kUsesColor2},
    {"scan", "Scan", kUsesColor | kUsesColor2 | kUsesSpeed},
};
const uint8_t kEffectCount = sizeof kEffects / sizeof kEffects[0];

namespace {

enum : uint8_t { kBreathe, kRainbow, kGradient, kScan };

constexpr float kTwoPi = 6.28318531f;

const uint16_t* linearTable() {
  static uint16_t table[256];
  static bool ready = false;
  if (!ready) {
    for (int i = 0; i < 256; i++) {
      table[i] = static_cast<uint16_t>(lroundf(powf(i / 255.0f, 2.2f) * 65535.0f));
    }
    ready = true;
  }
  return table;
}

// Geometric steps from the slowest period (speed 0) to the fastest (speed 255).
uint32_t period(uint8_t speed, float slowMs, float fastMs) {
  return static_cast<uint32_t>(slowMs * powf(fastMs / slowMs, speed / 255.0f));
}

Rgb16 widen(const Rgb& c) {
  return {static_cast<uint16_t>(c.r * 257), static_cast<uint16_t>(c.g * 257),
          static_cast<uint16_t>(c.b * 257)};
}

// Blends in linear light; the result is sRGB.
Rgb16 blend(const Rgb& a, const Rgb& b, uint16_t w) {
  return {linearToSrgb16(mix16(srgbToLinear(a.r), srgbToLinear(b.r), w)),
          linearToSrgb16(mix16(srgbToLinear(a.g), srgbToLinear(b.g), w)),
          linearToSrgb16(mix16(srgbToLinear(a.b), srgbToLinear(b.b), w))};
}

// Fully saturated color at hue h (0-65535 around the wheel).
Rgb16 hue(uint16_t h) {
  const uint32_t x = static_cast<uint32_t>(h) * 6;
  const uint16_t rise = static_cast<uint16_t>(x & 0xFFFF);
  const uint16_t fall = 65535 - rise;
  switch (x >> 16) {
    case 0: return {65535, rise, 0};
    case 1: return {fall, 65535, 0};
    case 2: return {0, 65535, rise};
    case 3: return {0, fall, 65535};
    case 4: return {rise, 0, 65535};
    default: return {65535, 0, fall};
  }
}

}  // namespace

int findEffect(const char* id) {
  if (!id) return -1;
  for (uint8_t i = 0; i < kEffectCount; i++) {
    if (!strcmp(kEffects[i].id, id)) return i;
  }
  return -1;
}

uint32_t effectPeriodMs(uint8_t effect, uint8_t speed) {
  switch (effect) {
    case kBreathe: return period(speed, 12000, 2000);
    case kRainbow: return period(speed, 60000, 2000);
    case kScan: return period(speed, 10000, 1000);
    default: return 0;
  }
}

void renderEffect(const LightState& s, uint16_t phase, Rgb16* out, uint16_t n) {
  switch (s.effect) {
    case kBreathe: {
      // Raised cosine: 100 % of `color` at phase 0, 15 % at half the cycle.
      const float k = 0.15f + 0.425f * (1.0f + cosf(phase * (kTwoPi / 65536.0f)));
      const uint32_t scale = static_cast<uint32_t>(k * 65535.0f);
      const Rgb16 c = widen(s.color);
      const Rgb16 v = {static_cast<uint16_t>(c.r * scale / 65535),
                       static_cast<uint16_t>(c.g * scale / 65535),
                       static_cast<uint16_t>(c.b * scale / 65535)};
      for (uint16_t i = 0; i < n; i++) out[i] = v;
      break;
    }
    case kRainbow:
      // One hue cycle across the strip, scrolling one strip length per cycle.
      for (uint16_t i = 0; i < n; i++) {
        out[i] = hue(static_cast<uint16_t>(i * 65536u / n + phase));
      }
      break;
    case kGradient:
      for (uint16_t i = 0; i < n; i++) {
        const uint16_t w = n > 1 ? static_cast<uint16_t>(i * 65535u / (n - 1)) : 0;
        out[i] = blend(s.color, s.color2, w);
      }
      break;
    case kScan: {
      // A soft band, 20 % of the strip wide, moves from the first LED to the last and back
      // once per cycle, over a `color2` background. Positions are in 1/256 LED.
      const uint32_t tri = phase < 32768 ? phase * 2u : (65535u - phase) * 2u;
      const int32_t center = static_cast<int32_t>(static_cast<uint64_t>(n - 1) * 256 * tri / 65534);
      const int32_t half = n * 256 / 10 > 256 ? n * 256 / 10 : 256;
      for (uint16_t i = 0; i < n; i++) {
        const int32_t d = abs(i * 256 - center);
        const uint16_t w = d >= half ? 0 : smoothstep16(static_cast<uint16_t>((half - d) * 65535 / half));
        out[i] = blend(s.color2, s.color, w);
      }
      break;
    }
    default:
      for (uint16_t i = 0; i < n; i++) out[i] = {0, 0, 0};
  }
}

void writeEffects(JsonArray out) {
  for (uint8_t i = 0; i < kEffectCount; i++) {
    JsonObject e = out.add<JsonObject>();
    e["id"] = kEffects[i].id;
    e["name"] = kEffects[i].name;
    JsonArray uses = e["uses"].to<JsonArray>();
    if (kEffects[i].uses & kUsesColor) uses.add("color");
    if (kEffects[i].uses & kUsesColor2) uses.add("color2");
    if (kEffects[i].uses & kUsesSpeed) uses.add("speed");
  }
}

uint16_t srgbToLinear(uint8_t c) { return linearTable()[c]; }

uint16_t linearToSrgb16(uint16_t linear) {
  if (linear == 0) return 0;
  const uint16_t* t = linearTable();
  // Largest i with t[i] <= linear, then interpolate towards i + 1.
  int lo = 0, hi = 255;
  while (lo < hi) {
    const int mid = (lo + hi + 1) / 2;
    if (t[mid] <= linear) {
      lo = mid;
    } else {
      hi = mid - 1;
    }
  }
  if (lo == 255) return 65535;
  const uint32_t span = t[lo + 1] - t[lo];
  const uint32_t frac = span ? (linear - t[lo]) * 257u / span : 0;
  return static_cast<uint16_t>(lo * 257 + frac);
}
