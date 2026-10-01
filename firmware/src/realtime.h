// DDP receiver and realtime rules (docs/protocol.md, Realtime: DDP).
#pragma once

#include <stddef.h>
#include <stdint.h>

#include "model.h"

struct DdpPacket {
  bool push;
  uint32_t offset;  // byte offset into the frame
  const uint8_t* data;
  uint16_t length;
};

// Parses a DDP header. False for packets the receiver drops.
bool parseDdp(const uint8_t* buf, size_t len, DdpPacket& out);

class Realtime {
 public:
  static constexpr uint32_t kTimeoutMs = 2500;
  static constexpr uint32_t kBlockMs = 1000;

  void begin(uint16_t ledCount);
  // Handles one UDP datagram from `sourceIp`. Frames are ignored while the light is off.
  void receive(uint32_t sourceIp, const uint8_t* buf, size_t len, bool on, uint32_t now);
  // PATCH with `mode`: ends the stream and ignores its sender until it has paused for
  // kBlockMs, so frames still in flight do not restart it.
  void end(uint32_t now);
  bool active(uint32_t now) const;
  uint32_t source() const { return source_; }
  const uint8_t* frame() const { return frame_; }

 private:
  uint16_t bytes_ = 0;
  bool streaming_ = false;
  uint32_t lastFrame_ = 0;
  uint32_t source_ = 0;
  uint32_t blocked_ = 0;
  uint32_t blockedUntil_ = 0;
  uint8_t work_[kMaxLeds * 3] = {};   // filled by packets
  uint8_t frame_[kMaxLeds * 3] = {};  // shown; copied from work_ on PUSH
};
