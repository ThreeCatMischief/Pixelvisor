// Frame composition and the output pipeline (docs/firmware-spec.md, Render pipeline).
#pragma once

#include "model.h"

enum class Overlay : uint8_t { None, Identify, Progress, Success, Failure, Setup };

// Picks the source (realtime, solid or effect) and applies crossfades and the brightness
// ramp. The frame stays in sRGB; brightness is applied by the Pipeline.
class Compositor {
 public:
  // Starts black and fades in to `s` over 800 ms.
  void begin(uint16_t n, const LightState& s, uint32_t now);
  // Renders the frame for `now`. `realtime` is the current DDP frame (RGB8) or null. A
  // change against the previous call starts a crossfade or brightness ramp lasting
  // `transitionMs`; entering realtime takes 150 ms, leaving it 400 ms.
  void render(const LightState& s, uint16_t transitionMs, const uint8_t* realtime, uint32_t now);
  const Rgb16* frame() const { return shown_; }
  uint16_t brightness() const { return brightness_; }  // 0-65535

 private:
  void renderSource(const LightState& s, const uint8_t* realtime, Rgb16* out) const;

  uint16_t n_ = 0;
  LightState prev_;
  bool prevRealtime_ = false;
  uint32_t last_ = 0;
  uint32_t phase_ = 0;  // effect cycle position, 2^32 per cycle
  uint32_t fadeStart_ = 0, fadeMs_ = 0;
  uint32_t rampStart_ = 0, rampMs_ = 0;
  uint16_t rampFrom_ = 0, rampTo_ = 0, brightness_ = 0;
  Rgb16 from_[kMaxLeds] = {};
  Rgb16 source_[kMaxLeds] = {};
  Rgb16 shown_[kMaxLeds] = {};
};

// Turns a composed frame into strip bytes: brightness, gamma, white balance, current
// limit, dither, then `reverse` and `color_order`.
class Pipeline {
 public:
  void configure(const DeviceConfig& c);  // rebuilds the gamma table when gamma changes
  void process(const Rgb16* frame, uint16_t brightness, uint8_t* out);
  // For overlays: values are already linear and are not dithered.
  void processLinear(const Rgb16* linear, uint8_t* out);
  // Replaces the first `count` logical LEDs of a finished frame; values are linear.
  void overlayLeds(const Rgb16* linear, uint16_t count, uint8_t* out) const;
  uint32_t currentMa() const { return currentMa_; }  // estimate for the last frame

 private:
  uint16_t gamma(uint16_t v) const;
  void finish(bool dither, uint8_t* out);

  DeviceConfig cfg_;
  bool seeded_ = false;
  float tableGamma_ = 0;
  uint8_t order_[3] = {};  // wire position of r, g, b
  uint32_t currentMa_ = 0;
  uint16_t table_[257] = {};
  uint16_t linear_[kMaxLeds * 3] = {};
  uint8_t error_[kMaxLeds * 3] = {};
};

// Status display (docs/firmware-spec.md, Status display). Writes linear values at a fixed
// low level and returns false once the overlay has ended.
bool renderOverlay(Overlay o, uint32_t elapsedMs, uint16_t permille, Rgb16* out, uint16_t n);
