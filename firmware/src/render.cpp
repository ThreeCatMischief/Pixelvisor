#include "render.h"

#include <math.h>
#include <string.h>

#include "effects.h"

namespace {

constexpr uint32_t kFadeInMs = 800;
constexpr uint32_t kRealtimeInMs = 150;
constexpr uint32_t kRealtimeOutMs = 400;

uint16_t target(const LightState& s) { return s.on ? s.brightness * 257 : 0; }

Rgb16 widen(uint8_t r, uint8_t g, uint8_t b) {
  return {static_cast<uint16_t>(r * 257), static_cast<uint16_t>(g * 257), static_cast<uint16_t>(b * 257)};
}

}  // namespace

void Compositor::begin(uint16_t n, const LightState& s, uint32_t now) {
  n_ = n;
  prev_ = s;
  prevRealtime_ = false;
  last_ = now;
  phase_ = 0;
  fadeMs_ = 0;
  rampFrom_ = 0;
  rampTo_ = target(s);
  rampStart_ = now;
  rampMs_ = kFadeInMs;
  brightness_ = 0;
  renderSource(s, nullptr, shown_);
}

void Compositor::render(const LightState& s, uint16_t transitionMs, const uint8_t* realtime, uint32_t now) {
  const bool live = realtime != nullptr;

  // The phase advances at the current speed, so a speed change continues without a jump.
  if (s.mode == Mode::Effect && (prev_.mode != Mode::Effect || s.effect != prev_.effect)) phase_ = 0;
  const uint32_t period = effectPeriodMs(s.effect, s.speed);
  if (period) phase_ += static_cast<uint32_t>((static_cast<uint64_t>(now - last_) << 32) / period);
  last_ = now;

  bool changed;
  uint32_t fadeMs = transitionMs;
  if (live != prevRealtime_) {
    changed = true;
    fadeMs = live ? kRealtimeInMs : kRealtimeOutMs;
  } else if (live) {
    changed = false;  // state changes show once the stream ends
  } else if (s.mode != prev_.mode) {
    changed = true;
  } else if (s.mode == Mode::Solid) {
    changed = s.color != prev_.color;
  } else {
    const uint8_t uses = kEffects[s.effect].uses;
    changed = s.effect != prev_.effect || ((uses & kUsesColor) && s.color != prev_.color) ||
              ((uses & kUsesColor2) && s.color2 != prev_.color2);
  }
  if (changed) {
    memcpy(from_, shown_, n_ * sizeof(Rgb16));
    fadeStart_ = now;
    fadeMs_ = fadeMs;
  }

  const uint16_t to = target(s);
  if (to != rampTo_) {
    rampFrom_ = brightness_;
    rampTo_ = to;
    rampStart_ = now;
    rampMs_ = transitionMs;
  }
  const uint32_t t = now - rampStart_;
  brightness_ = t >= rampMs_ ? rampTo_
                             : static_cast<uint16_t>(rampFrom_ + (static_cast<int32_t>(rampTo_) - rampFrom_) *
                                                                     static_cast<int32_t>(t) / static_cast<int32_t>(rampMs_));

  renderSource(s, realtime, source_);
  const uint32_t f = now - fadeStart_;
  if (f < fadeMs_) {
    const uint16_t w = smoothstep16(static_cast<uint16_t>(f * 65535 / fadeMs_));
    for (uint16_t i = 0; i < n_; i++) {
      shown_[i] = {mix16(from_[i].r, source_[i].r, w), mix16(from_[i].g, source_[i].g, w),
                   mix16(from_[i].b, source_[i].b, w)};
    }
  } else {
    memcpy(shown_, source_, n_ * sizeof(Rgb16));
  }

  prev_ = s;
  prevRealtime_ = live;
}

void Compositor::renderSource(const LightState& s, const uint8_t* realtime, Rgb16* out) const {
  if (realtime) {
    for (uint16_t i = 0; i < n_; i++) out[i] = widen(realtime[i * 3], realtime[i * 3 + 1], realtime[i * 3 + 2]);
  } else if (s.mode == Mode::Solid) {
    const Rgb16 c = widen(s.color.r, s.color.g, s.color.b);
    for (uint16_t i = 0; i < n_; i++) out[i] = c;
  } else {
    renderEffect(s, static_cast<uint16_t>(phase_ >> 16), out, n_);
  }
}

void Pipeline::configure(const DeviceConfig& c) {
  if (!seeded_) {
    // Different starting errors per channel spread the dither steps over time, so LEDs
    // showing the same value do not step together.
    for (size_t k = 0; k < sizeof error_; k++) error_[k] = static_cast<uint8_t>(k * 97);
    seeded_ = true;
  }
  if (c.gamma != tableGamma_) {
    for (int i = 0; i <= 256; i++) {
      table_[i] = static_cast<uint16_t>(lroundf(powf(i / 256.0f, c.gamma) * 65535.0f));
    }
    tableGamma_ = c.gamma;
  }
  const char* order = kColorOrders[c.colorOrder];
  for (uint8_t k = 0; k < 3; k++) order_[order[k] == 'R' ? 0 : order[k] == 'G' ? 1 : 2] = k;
  cfg_ = c;
}

uint16_t Pipeline::gamma(uint16_t v) const {
  const uint32_t p = static_cast<uint32_t>(v) * 65536 / 65535;  // table position, 8.8 fixed point
  const uint32_t i = p >> 8;
  if (i >= 256) return table_[256];
  return static_cast<uint16_t>(table_[i] + ((table_[i + 1] - table_[i]) * (p & 0xFF) >> 8));
}

void Pipeline::process(const Rgb16* frame, uint16_t brightness, uint8_t* out) {
  const uint32_t wb[3] = {cfg_.whiteBalance.r, cfg_.whiteBalance.g, cfg_.whiteBalance.b};
  for (uint16_t i = 0; i < cfg_.ledCount; i++) {
    const uint16_t c[3] = {frame[i].r, frame[i].g, frame[i].b};
    for (int k = 0; k < 3; k++) {
      // Brightness before gamma, so the brightness scale is perceptually even.
      const uint32_t v = static_cast<uint32_t>(c[k]) * brightness / 65535;
      linear_[i * 3 + k] = static_cast<uint16_t>(gamma(static_cast<uint16_t>(v)) * wb[k] / 255);
    }
  }
  finish(cfg_.dither, out);
}

void Pipeline::processLinear(const Rgb16* linear, uint8_t* out) {
  for (uint16_t i = 0; i < cfg_.ledCount; i++) {
    linear_[i * 3] = linear[i].r;
    linear_[i * 3 + 1] = linear[i].g;
    linear_[i * 3 + 2] = linear[i].b;
  }
  finish(false, out);
}

void Pipeline::finish(bool dither, uint8_t* out) {
  const uint16_t n = cfg_.ledCount;

  // Current estimate: up to ma_per_channel per channel, plus about 1 mA per LED at idle.
  // Over the limit, the LED part is scaled down to fit the budget left after idle current.
  uint32_t sum = 0;
  for (uint32_t k = 0; k < n * 3u; k++) sum += linear_[k];
  const uint32_t ledMa = static_cast<uint32_t>(static_cast<uint64_t>(sum) * cfg_.maPerChannel / 65535);
  uint32_t scale = 65536;  // 16.16
  if (cfg_.maxCurrentMa && ledMa > 0 && ledMa + n > cfg_.maxCurrentMa) {
    const uint32_t budget = cfg_.maxCurrentMa > n ? cfg_.maxCurrentMa - n : 0;
    scale = static_cast<uint32_t>(static_cast<uint64_t>(budget) * 65536 / ledMa);
  }
  currentMa_ = static_cast<uint32_t>(static_cast<uint64_t>(ledMa) * scale >> 16) + n;

  for (uint16_t i = 0; i < n; i++) {
    const uint16_t p = cfg_.reverse ? n - 1 - i : i;
    for (int k = 0; k < 3; k++) {
      const uint32_t v = static_cast<uint32_t>(linear_[i * 3 + k]) * scale >> 16;
      uint8_t& error = error_[i * 3 + k];
      uint8_t o;
      if (v == 0) {
        o = 0;  // black stays black, with no dither shimmer
        error = 0;
      } else {
        const uint32_t q = (v * 65280 + 32767) / 65535;  // 8.8 fixed point, 0-255.0
        if (dither) {
          const uint32_t acc = q + error;
          o = static_cast<uint8_t>(acc >> 8);
          error = static_cast<uint8_t>(acc & 0xFF);
        } else {
          o = static_cast<uint8_t>((q + 128) >> 8);
        }
      }
      out[p * 3 + order_[k]] = o;
    }
  }
}

void Pipeline::overlayLeds(const Rgb16* linear, uint16_t count, uint8_t* out) const {
  const uint16_t n = cfg_.ledCount;
  for (uint16_t i = 0; i < count && i < n; i++) {
    const uint16_t p = cfg_.reverse ? n - 1 - i : i;
    const uint16_t c[3] = {linear[i].r, linear[i].g, linear[i].b};
    for (int k = 0; k < 3; k++) {
      out[p * 3 + order_[k]] = static_cast<uint8_t>(((c[k] * 65280u + 32767u) / 65535u + 128) >> 8);
    }
  }
}

bool renderOverlay(Overlay o, uint32_t elapsedMs, uint16_t permille, Rgb16* out, uint16_t n) {
  constexpr uint16_t kLevel = 40 * 257;  // fixed, independent of master brightness
  Rgb16 color;
  bool lit = true;
  uint32_t count = n;
  switch (o) {
    case Overlay::Identify:  // three white flashes
      if (elapsedMs >= 1500) return false;
      color = {kLevel, kLevel, kLevel};
      lit = elapsedMs % 500 < 250;
      break;
    case Overlay::Progress:  // cyan bar from the first LED
      color = {0, kLevel, kLevel};
      count = static_cast<uint32_t>(n) * (permille > 1000 ? 1000 : permille) / 1000;
      break;
    case Overlay::Success:  // green until the reboot
      if (elapsedMs >= 2000) return false;
      color = {0, kLevel, 0};
      break;
    case Overlay::Setup: {  // blue breathing, 2 s period; `elapsedMs` is the uptime
      const float k = 0.5f + 0.5f * cosf(static_cast<float>(elapsedMs % 2000) * (6.28318531f / 2000.0f));
      color = {0, 0, static_cast<uint16_t>(kLevel * (0.15f + 0.85f * k))};
      break;
    }
    case Overlay::Failure:  // three red flashes
      if (elapsedMs >= 1500) return false;
      color = {kLevel, 0, 0};
      lit = elapsedMs % 500 < 250;
      break;
    default:
      return false;
  }
  for (uint16_t i = 0; i < n; i++) out[i] = lit && i < count ? color : Rgb16{0, 0, 0};
  return true;
}
