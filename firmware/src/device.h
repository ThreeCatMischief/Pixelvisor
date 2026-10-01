// Runtime state shared by the HTTP handlers (loop task) and the render task. Access it
// only while holding a Lock.
#pragma once

#include <Arduino.h>

#include "model.h"
#include "render.h"

struct Device {
  SemaphoreHandle_t mutex = nullptr;
  char id[7] = "";        // last 3 bytes of the WiFi MAC; set at boot
  DeviceConfig config;    // as stored; reboot fields take effect after a restart
  DeviceConfig running;   // as booted; read-only after setup()
  LightState state;
  uint32_t rev = 0;
  uint16_t transitionMs = 400;    // of the last state patch
  bool endRealtime = false;       // set by a PATCH with mode, cleared by the render task
  bool realtimeActive = false;    // reported by the render task
  uint32_t realtimeSource = 0;    // IPv4 address
  Overlay overlay = Overlay::None;
  uint32_t overlayStart = 0;
  uint16_t progress = 0;          // permille, for Overlay::Progress
  bool stateDirty = false;        // persisted 5 s after the last change
  uint32_t stateChangedAt = 0;
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

inline void showOverlay(Overlay o) {
  Lock lock;
  dev.overlay = o;
  dev.overlayStart = millis();
  dev.progress = 0;
}

inline void setProgress(uint16_t permille) {
  Lock lock;
  dev.progress = permille;
}

// Stores the config in NVS (main.cpp).
void saveConfig(const DeviceConfig& c);
