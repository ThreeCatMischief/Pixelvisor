# Firmware Specification

ESP32 firmware for Pixelvisor (ESP32-C3 and classic ESP32). It implements [protocol.md](protocol.md) and works as a
standalone lamp: it restores its last state at power-on and renders without a network or a
client.

## Requirements

| # | Requirement | Status |
| --- | --- | --- |
| F1 | Implements protocol API v1 (HTTP control, DDP realtime, mDNS). | Done |
| F2 | Renders at a fixed rate with smooth transitions. No visible flicker, including during WiFi traffic. | Done; flicker to be checked on the device |
| F3 | Restores state after power loss per `power_on`. Works with no WiFi. | Done |
| F4 | Limits estimated current to `max_current_ma`. | Done |
| F5 | No credentials in the build. WiFi is set up at runtime through a setup portal. | Done |
| F6 | No physical controls. A device that cannot reach its network opens the setup portal by itself. | Done |
| F7 | Hardware parameters (LED count, pin, color order, current) are runtime config with compile-time defaults. A public binary works on other builds without recompiling. | Done |
| F8 | Updates over the air through `POST /api/ota`, for development and users. | Done |
| F9 | Hardware-independent logic builds and is unit-tested on the host (`pio test -e native`). | Done |

## Reference hardware

The defaults target this build; everything in this table except the MCU is
runtime-configurable.

| Part | Reference | Notes |
| --- | --- | --- |
| MCU | ESP32-C3 SuperMini (board definition `esp32-c3-devkitm-1`) | Single core, USB-CDC console. Classic ESP32 dev boards work with the `esp32dev` env (default data pin GPIO 16). |
| Strip | WS2812B, 60 LEDs/m, 720 mm = 43 LEDs, 5 V, GRB | |
| Supply | 5 V | Worst case 43 × 60 mA = 2.6 A for LEDs + ~250 mA for the ESP32. Set `max_current_ma` to the supply rating minus 300 mA. |
| Data line | GPIO 4 → 74AHCT125 (5 V) → 330 Ω → DIN | WS2812B needs V_IH ≥ 0.7 × VDD = 3.5 V at 5 V. The 3.3 V GPIO level is out of spec and often works, but the level shifter makes it reliable. |
| Bulk cap | 1000 µF across 5 V/GND at the strip input | |
| Power | ESP32 fed from the same 5 V; common ground | Without USB power only, set `max_current_ma` ≤ 400. |

At 43 LEDs no power injection is needed.

## Repository layout (firmware part)

The PlatformIO project is the repo root, so the PlatformIO IDE opens the repo like any other
project. All firmware sources sit in one flat folder.

```
platformio.ini            # envs: esp32-c3-supermini (default), esp32dev, ota, native
firmware/
├── src/
│   ├── main.cpp          # setup/loop, render task, NVS persistence
│   ├── network.cpp/.h    # WiFi, setup portal, mDNS
│   ├── api.cpp/.h        # HTTP handlers, firmware upload
│   ├── device.h          # state shared between the loop and the render task
│   ├── page.h            # web UI and setup page served at GET /
│   ├── model.cpp/.h      # LightState, DeviceConfig, JSON validation, compile-time defaults
│   ├── effects.cpp/.h    # effect table and renderers, sRGB/linear helpers
│   ├── render.cpp/.h     # Compositor (sources, crossfades), Pipeline (output), overlays
│   └── realtime.cpp/.h   # DDP parser and realtime rules
└── test/test_core/       # host tests
protocol/fixtures/        # shared with apps and tools
tools/                    # ddp_send.py, check_device.py, mock_device.py
```

Rule: `model`, `effects`, `render` and `realtime` include only the standard library and
ArduinoJson. The `native` env compiles exactly these four files.

## Build configuration

| Env | Use |
| --- | --- |
| `esp32-c3-supermini` | Default. `pio run -t upload -t monitor` flashes over USB. |
| `esp32dev` | Classic ESP32 dev boards. |
| `ota` | Same image, uploaded with `curl` to `POST /api/ota` on `pixelvisor.local`. `pio run -e ota -t upload`. |
| `native` | `pio test -e native`: host tests against `protocol/fixtures/`. |

The device envs set the board-specific defaults below. The platform is pinned to a
pioarduino release, so builds are reproducible. Release builds set `LB_FW_VERSION` from the
git tag through `PLATFORMIO_BUILD_FLAGS`.

Compile-time defaults live in `model.h`, each `#ifndef`-guarded:

| Macro | Default | Meaning |
| --- | --- | --- |
| `LB_DEFAULT_HOSTNAME` | `"pixelvisor"` | Default `hostname` |
| `LB_DEFAULT_NAME` | `"Pixelvisor"` | Default `name` |
| `LB_DEFAULT_LED_COUNT` | `43` | |
| `LB_DEFAULT_DATA_PIN` | `4` (`16` for `esp32dev`) | |
| `LB_DEFAULT_MAX_CURRENT_MA` | `1500` | Conservative public default |
| `LB_DATA_PINS` | ESP32-C3 list | Pins accepted as `data_pin` (see Boards) |
| `LB_FW_VERSION` | `"0.1.0"` | Reported in `/api/info` and TXT `fw`. Bump it with each release. |

## Libraries

| Library | License | Use |
| --- | --- | --- |
| Arduino-ESP32 core: `WiFi`, `WiFiUdp`, `WebServer`, `ESPmDNS`, `Preferences`, `Update` | LGPL-2.1 | Platform |
| ArduinoJson 7 | MIT | JSON in the model |
| Adafruit NeoPixel | LGPL-3.0 | Pixel output only (RMT). Pin and count are set at boot; the pipeline applies `color_order` itself and hands the library finished bytes (`NEO_RGB`). |

Color math, gamma, dithering and effects are our own code, small and host-testable.

## Architecture

```
UDP 4048 ──▶ render task: parsePacket ─▶ Realtime ───────────────────┐
                                                                     ▼
HTTP 80 ──▶ loop(): WebServer ─▶ handlers ─▶ dev (mutex) ─▶ render task, every 8 ms:
            WiFi reconnect, NVS persistence           snapshot ─▶ Compositor ─▶ Pipeline
                                                               ─▶ overlay ─▶ strip.show()
```

The C3 has one core. Two tasks share it:

| Task | Priority | Work |
| --- | --- | --- |
| `render` | 5 | Every 8 ms (16 ms above 200 LEDs) via `vTaskDelayUntil`: reads all pending DDP datagrams, takes a snapshot of `dev`, composes and outputs one frame. Never waits on the network. |
| Arduino `loop()` | 1 | HTTP, WiFi reconnect, NVS writes, scheduled restarts |

- `dev` (`device.h`) holds config, state, `rev`, the realtime status and overlay requests,
  guarded by one FreeRTOS mutex. Handlers validate a patch and apply it under the lock; the
  render task copies what it needs once per frame.
- The realtime buffer belongs to the render task, which also reads the UDP socket, so it
  needs no lock. A PATCH with `mode` sets `endRealtime`; the render task ends the stream
  on its next frame.
- A strip write takes 1.3 ms plus the 280 µs reset at 43 LEDs. The render task waits for
  it without using the CPU.

## Render pipeline

Per frame, in `render.cpp`, independent of Arduino. Values are 16 bit per channel from the
source to the dither step.

1. **Source frame (sRGB).** Realtime frame while a stream is active; otherwise `color` for
   `mode == solid`, or the effect for `mode == effect`.
2. **Transition.** When the visible source changes (mode, a color the source uses, the
   effect, realtime start or end), the last shown frame becomes `from` and blends into the
   live source with smoothstep easing: `transition_ms` of the patch, 150 ms into realtime,
   400 ms out of it. Animated effects keep running underneath. A speed change does not
   crossfade: the effect phase advances at the current speed, so it continues without a
   jump. `on` and `brightness` ramp linearly over the same duration; at boot the strip
   fades in from black over 800 ms.
3. **Brightness.** Scale by the ramped brightness, before gamma, so the scale is
   perceptually even.
4. **Gamma.** 257-entry table with linear interpolation, rebuilt when `gamma` changes.
5. **White balance.** Per-channel multiply by `white_balance / 255`.
6. **Current limit.** `I = Σ(channel / 65535 × ma_per_channel) + led_count × 1 mA`. Above
   `max_current_ma`, the LED part is scaled to fit what is left after the idle current, so
   the estimate after limiting is at most the limit.
7. **Dither and quantise.** 16 → 8 bit with per-channel error accumulation when `dither` is
   on; otherwise round. Channels start with different errors, so LEDs showing the same value
   do not step together. Exactly 0 stays 0.
8. **Map and write.** `reverse`, then `color_order`, into the NeoPixel buffer.

Overlays replace steps 1–5 while active; their values are linear and are not dithered.

## Effects

Static table in `effects.cpp`: `{ id, name, uses }`. `GET /api/effects` serialises it.
Speed maps geometrically from the slowest period (speed 0) to the fastest (255).

| ID | Uses | Behaviour | Period |
| --- | --- | --- | --- |
| `breathe` | color, speed | Raised-cosine brightness modulation of `color` between 100 % and 15 %, starting at 100 % | 12 s → 2 s |
| `rainbow` | speed | Hue gradient, one full cycle across the strip, scrolling one strip length per period | 60 s → 2 s |
| `gradient` | color, color2 | Static blend `color → color2` from the first LED to the last, in linear light | static |
| `scan` | color, color2, speed | A soft `color` band, 20 % of the strip wide, from the first LED to the last and back over `color2`, blended in linear light | 10 s → 1 s |

A new effect needs a table entry, a renderer, an entry in `protocol/fixtures/effects.json`
and a test. Clients pick it up from `/api/effects` without code changes. Anything beyond
these, such as screen mirroring or custom animations, is streamed over DDP.

## Persistence (NVS)

| Namespace | Key | Written when |
| --- | --- | --- |
| `state` | `json`: the `GET /api/state` body, including `rev` | 5 s after the last change, and before a restart. Realtime is never stored. |
| `config` | `json`: the `GET /api/config` body | Immediately on `PATCH /api/config` |

JSON storage lets fields be added without migration code. A stored value that fails
validation falls back to defaults and is logged. The 5 s delay keeps slider drags from
writing flash repeatedly. `rev` is stored, so a power cycle does not look like a change by
another client.

At boot, per `power_on`: `restore` uses the stored state; `on` and `off` override `on`.
Any override increments `rev`.

## WiFi

- Credentials live in NVS (`wifi`: `ssid`, `pass`). They survive firmware updates.
- Without credentials, the device opens the open setup network `Pixelvisor-<id>` (AP at
  192.168.4.1) with a DNS server that answers every name with its own address, so phones
  show the setup page as a captive portal. The page scans for networks and sends
  `POST /api/wifi`; the device stores the credentials and restarts.
- With credentials: STA with `WiFi.setHostname(hostname)` before the interface starts,
  `WiFi.setSleep(false)` (modem sleep adds 100+ ms latency and drops realtime packets) and a
  new attempt every 20 s while disconnected. No connection 30 s after boot, or 3 min after
  losing it, opens the setup network alongside (AP+STA); it closes once the STA connects.
  While a client is on the setup network, STA attempts pause, because they can move the
  radio off the AP's channel.
- On the first connection: mDNS (hostname, instance name, `_http._tcp`, and
  `_pixelvisor._tcp` with TXT `id`, `api`, `fw`, `leds`, `ddp`). It keeps running across
  reconnects. A `name` change updates the instance name at once.
- `DELETE /api/wifi` clears the credentials and restarts into setup.
- Rendering never depends on connectivity.

## HTTP server

- Arduino `WebServer`, handled from `loop()`. Request rate is low, and the render task runs
  independently.
- Request bodies up to 2 KB go through the raw handler, so the content type does not
  matter: `curl -d '{...}'` works without `-H Content-Type`.
- Every response carries `Access-Control-Allow-Origin: *` (`enableCORS`); `OPTIONS`
  answers preflight with 204.
- Handlers parse with the model functions and apply under the lock; validation lives only
  in `model.cpp`.
- `GET /` serves the web UI: control (power, brightness, color, effects), settings (all of
  `/api/config`), identify, reboot, firmware update and Forget WiFi. While the setup portal
  is open it serves the setup page instead. Both use only the public API.

## OTA

`POST /api/ota` streams the raw image into `Update`, with the optional `X-Firmware-MD5`
check. Status display: a cyan progress bar, then green until the restart one second after
the response, or three red flashes on failure while the old image keeps running.
`min_spiffs.csv` provides two 1.9 MB app slots; the image uses about 1.1 MB.

`pio run -e ota -t upload` uses the same endpoint, so development and app updates share
one code path. There is no ArduinoOTA.

## Status display

The strip is the only indicator. Overlays are drawn at a fixed low level (40 of 255,
linear) regardless of master brightness.

| Condition | Display |
| --- | --- |
| Identify (`/api/identify`) | Whole strip flashes white 3× over 1.5 s |
| OTA in progress | Cyan bar proportional to progress |
| OTA success | Green until the restart |
| OTA failure | Whole strip flashes red 3× |
| Setup portal open | LEDs 0–2 breathe blue; the rest shows the normal state |

## Logging

`ESP_LOGx` with tag `pixelvisor`; the Arduino core routes it to the USB-CDC console. Level 3
(info) from `CORE_DEBUG_LEVEL`. No credentials in logs; the SSID is logged, the password
never is.

## Boards

`LB_DATA_PINS` is the per-board allowlist for `data_pin`. ESP32-C3: 0, 1, 3, 4, 5, 6, 7, 10,
20. This excludes the strapping pins 2, 8 and 9, the flash pins 11–17, the USB pins 18 and
19, and GPIO 21 (U0TXD), which carries the ROM boot log and would flash the strip at every
boot. Classic ESP32 (`esp32dev`): 4, 13, 14, 16–19, 21–23, 25–27, 32, 33, which excludes the
flash pins 6–11, the input-only pins 34–39 and the strapping pins 0, 2, 5, 12, 15.

## Testing

### Host tests (`pio test -e native`)

One suite, `firmware/test/test_core`:

| Area | Covers |
| --- | --- |
| Fixtures | Default state, config and effect list equal `state.json`, `config.json`, `effects.json`; every case in `state_patches.json`, `config_patches.json` and `ddp.json` |
| State model | All-or-nothing validation, `changed` only on new values, `mode` flag |
| Realtime | Timeout, ignored while off, end blocks the sender until it pauses, other senders unaffected, most recent sender wins |
| Pipeline | Brightness 0 is black; gamma monotonic; white balance; current limit holds the limit and leaves frames under it unchanged; dither average converges; black stays black; `reverse` and `color_order` |
| Composition | Boot fade-in; crossfade endpoints exact; duration 0 applies at once; brightness ramp and off; realtime crossfades in and out |
| Effects | Deterministic, no writes past n for n = 1, 43, 480; breathe range; gradient and scan endpoints; speed → period; sRGB/linear round trip |
| Overlays | Identify timing, progress bar length |

### On-device checks (manual, per release)

Recorded in `docs/test-log.md` with date and firmware version.

1. Stream DDP at 60 fps (`tools/                    # ddp_send.py, check_device.py, mock_device.py <host> --pattern rainbow --fps 60`) for 10 min:
   no flicker, no stuck frames, `free_heap` stable.
2. `PATCH` brightness at 10 Hz during the stream: no stutter.
3. Pull power during a slider drag, restore: previous state within 5 s tolerance.
4. Router off, then on: device reconnects without a power cycle; the bar stays lit
   throughout.
5. OTA via `POST /api/ota`, including an interrupted upload (old image keeps running).
6. At full white, measured current ≤ `max_current_ma` + 10 %.
7. `ddp_send.py --pattern index`: red at the left end, after setting `reverse` if needed.

If check 1 shows flicker: the NeoPixel RMT driver refills the C3's 48-symbol RMT memory
from an interrupt, and that interrupt cannot run while flash is busy (NVS writes, OTA).
The fix is an SPI-DMA output behind the same buffer; nothing else changes.

## Not implemented yet

- Improv Serial (WiFi setup from the web flasher). The setup portal covers first setup.
- Power-cycle recovery (quick power cycles to clear WiFi or reset to defaults). A device
  that cannot reach its network opens the setup portal by itself.
