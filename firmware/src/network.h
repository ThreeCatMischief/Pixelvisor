// WiFi with runtime setup (docs/firmware-spec.md, WiFi). Credentials live in NVS and are
// entered through a setup portal: the device opens the open network "Pixelvisor-<id>" when
// it has no credentials or cannot reach its network.
#pragma once

#include <ArduinoJson.h>

void netBegin();
void netLoop();
bool netPortalActive();
// Stores credentials; the caller restarts the device.
void netSave(const char* ssid, const char* password);
// Clears stored credentials; the caller restarts the device.
void netForget();
// Networks in range, strongest first: [{"ssid", "rssi", "secure"}].
void netScan(JsonArray out);
