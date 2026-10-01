#include "realtime.h"

#include <string.h>

namespace {

constexpr uint8_t kFlagTimecode = 0x10;
constexpr uint8_t kFlagPush = 0x01;

uint32_t be32(const uint8_t* p) {
  return static_cast<uint32_t>(p[0]) << 24 | static_cast<uint32_t>(p[1]) << 16 |
         static_cast<uint32_t>(p[2]) << 8 | p[3];
}

}  // namespace

bool parseDdp(const uint8_t* buf, size_t len, DdpPacket& out) {
  if (len < 10) return false;
  const uint8_t flags = buf[0];
  if (flags >> 6 != 1) return false;  // version 1
  const uint8_t type = buf[2];
  if (type != 0x00 && type != 0x01 && type != 0x0B) return false;
  const uint8_t destination = buf[3];
  if (destination != 1 && destination != 255) return false;
  const size_t header = (flags & kFlagTimecode) ? 14 : 10;  // timecode bytes are skipped
  if (len < header) return false;

  const uint16_t length = static_cast<uint16_t>(buf[8] << 8 | buf[9]);
  out.push = (flags & kFlagPush) != 0;
  out.offset = be32(buf + 4);
  out.data = buf + header;
  out.length = length < len - header ? length : static_cast<uint16_t>(len - header);
  return true;
}

void Realtime::begin(uint16_t ledCount) { bytes_ = ledCount * 3; }

void Realtime::receive(uint32_t sourceIp, const uint8_t* buf, size_t len, bool on, uint32_t now) {
  DdpPacket p;
  if (!parseDdp(buf, len, p)) return;
  if (blocked_) {
    if (static_cast<int32_t>(now - blockedUntil_) >= 0) {
      blocked_ = 0;
    } else if (sourceIp == blocked_) {
      blockedUntil_ = now + kBlockMs;
      return;
    }
  }
  if (!on) return;

  if (p.offset < bytes_) {
    const size_t n = p.length < bytes_ - p.offset ? p.length : bytes_ - p.offset;
    memcpy(work_ + p.offset, p.data, n);
  }
  if (p.push) {
    memcpy(frame_, work_, bytes_);
    streaming_ = true;
    lastFrame_ = now;
    source_ = sourceIp;
  }
}

void Realtime::end(uint32_t now) {
  if (active(now)) {
    blocked_ = source_;
    blockedUntil_ = now + kBlockMs;
  }
  streaming_ = false;
}

bool Realtime::active(uint32_t now) const { return streaming_ && now - lastFrame_ < kTimeoutMs; }
