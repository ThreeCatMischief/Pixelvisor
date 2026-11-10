// Runtime state shared by the HTTP handlers (loop task) and the render task. Access it
// only while holding a Lock.
#pragma once

#include <Arduino.h>

#include "model.h"
#include "render.h"

// One strip: its config, light state and the flags exchanged with the render task.
struct Channel {
  DeviceConfig config;    // as stored; reboot fields take effect after a restart
  DeviceConfig running;   // as booted; read-only after setup()
  LightState state;
  uint32_t rev = 0;
  uint16_t transitionMs = 400;    // of the last state patch
  Transition transition = Transition::Fade;  // of the last state patch
  bool endRealtime = false;       // set by a PATCH with mode, cleared by the render task
  bool realtimeActive = false;    // reported by the render task
  uint32_t realtimeSource = 0;    // IPv4 address
  Overlay overlay = Overlay::None;
  uint32_t overlayStart = 0;
  uint16_t progress = 0;          // permille, for Overlay::Progress
  bool stateDirty = false;        // persisted 5 s after the last change
  uint32_t stateChangedAt = 0;
};

struct Device {
  SemaphoreHandle_t mutex = nullptr;
  char id[7] = "";        // last 3 bytes of the WiFi MAC; set at boot
  Channel ch[kStrips];
  uint32_t restartAt = 0;         // 0: no restart scheduled
  bool portal = false;            // setup portal open (network.cpp)
};

extern Device dev;

class Lock {
 public:
  Lock() { xSemaphoreTake(dev.mutex, portMAX_DELAY); }
  ~Lock() { xSemaphoreGive(dev.mutex); }
  Lock(const Lock&) = delete;
  Lock& operator=(const Lock&) = delete;
};

// Shows a status overlay on strip `strip`, or on all strips when negative.
inline void showOverlay(Overlay o, int strip = -1) {
  Lock lock;
  for (int i = 0; i < kStrips; i++) {
    if (strip >= 0 && i != strip) continue;
    dev.ch[i].overlay = o;
    dev.ch[i].overlayStart = millis();
    dev.ch[i].progress = 0;
  }
}

inline void setProgress(uint16_t permille) {
  Lock lock;
  for (Channel& c : dev.ch) c.progress = permille;
}

// Stores the config of strip `strip` in NVS (main.cpp).
void saveConfig(int strip, const DeviceConfig& c);
