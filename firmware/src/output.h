// WS2812B output on the ESP32 RMT peripheral, one instance per data pin. Each instance keeps
// its RMT channel, so strips on different pins can be shown back to back. (Adafruit NeoPixel
// shares one channel between instances and re-initialises it on every pin change.)
#pragma once

#include <Arduino.h>

class StripOutput {
 public:
  bool begin(uint8_t pin, uint16_t ledCount) {
    pin_ = pin;
    bytes_ = ledCount * 3u;
    symbols_ = static_cast<rmt_data_t*>(malloc(bytes_ * 8 * sizeof(rmt_data_t)));
    return symbols_ && rmtInit(pin, RMT_TX_MODE, RMT_MEM_NUM_BLOCKS_1, 10000000);  // 0.1 us ticks
  }

  // Sends `bytes_` bytes in wire order and returns when the last bit is out.
  void show(const uint8_t* data) {
    if (!symbols_) return;
    size_t i = 0;
    for (size_t b = 0; b < bytes_; b++) {
      for (int bit = 7; bit >= 0; bit--, i++) {
        const bool one = data[b] >> bit & 1;
        symbols_[i].level0 = 1;
        symbols_[i].duration0 = one ? 8 : 4;  // 0.8 us / 0.4 us high
        symbols_[i].level1 = 0;
        symbols_[i].duration1 = one ? 4 : 8;
      }
    }
    rmtWrite(pin_, symbols_, bytes_ * 8, RMT_WAIT_FOR_EVER);
  }

 private:
  uint8_t pin_ = 0;
  size_t bytes_ = 0;
  rmt_data_t* symbols_ = nullptr;
};
