# Pixelvisor

A WiFi LED light bar for the top of a monitor. An ESP32 drives a WS2812B strip; you control
it from its built-in web page (any browser, Windows, Linux, phones) or from the macOS menu
bar app, which can also follow your monitor's brightness and mirror the top of your screen.

- Solid colors, white temperatures and effects (breathe, rainbow, gradient, scan), with
  smooth fades.
- Restores its last state after a power cut; works without a network.
- WiFi setup from your phone: no credentials in the firmware, no tools needed.
- Open HTTP/JSON API and the public DDP protocol, so other tools (xLights, LedFx, WLED
  senders, scripts) can drive it too. See [docs/protocol.md](docs/protocol.md).

## What you need

| Part | Notes |
| --- | --- |
| ESP32-C3 SuperMini | Or a classic ESP32 dev board (ESP32-WROOM-32). |
| WS2812B strip, 5 V, 60 LEDs/m | 720 mm = 43 LEDs. Any length up to 480 LEDs works; set the LED count in Settings. |
| 5 V supply | About 60 mA per LED at full white. A 3 A supply covers 43 LEDs. |
| 74AHCT125 level shifter, 330 Ω resistor, 1000 µF capacitor | Recommended for a reliable data signal; many strips also work without the shifter. |

Wiring:

```
5 V supply + ──┬──────────────── strip 5V
               ├── 1000 µF ──┐
               └── ESP32 5V  │
5 V supply − ──┴─────────────┴── strip GND ── ESP32 GND
ESP32 GPIO 4 ── 74AHCT125 ── 330 Ω ── strip DIN      (classic ESP32: GPIO 16)
```

## Install

### 1. Flash the firmware

**From the browser (easiest).** Open the project's flasher page in Chrome or Edge, plug in
the board with a USB data cable, and click *Install*. The page is published from this
repository with each release (GitHub Pages, see [Releasing](#releasing)).

**With PlatformIO.** Install [PlatformIO](https://platformio.org) (the VS Code extension
or `pip install platformio`), then from this folder:

```sh
pio run -t upload                 # ESP32-C3 SuperMini
pio run -e esp32dev -t upload     # classic ESP32
```

**With esptool.** Download `pixelvisor-esp32c3-<version>-factory.bin` (or `-esp32-`) from
the releases page and run `esptool.py write_flash 0x0 pixelvisor-…-factory.bin`.

### 2. Connect it to WiFi

1. Power the bar. With no WiFi configured, the first three LEDs breathe blue.
2. On your phone or laptop, join the open WiFi network **Pixelvisor-xxxxxx**. The setup page
   opens by itself; if not, open <http://192.168.4.1>.
3. Pick your network, enter the password, tap *Connect*. The bar restarts and joins it.

If the bar later cannot reach its network for 3 minutes, it opens the setup network again
until you choose a new one. *Forget WiFi* in the web page or the app does the same at once.

### 3. Control it

- **Browser:** <http://pixelvisor.local> (or the bar's IP address from your router). Power,
  brightness, color, effects, settings, firmware updates.
- **macOS:** download `Pixelvisor-macOS-<version>.zip` from the releases page, unzip, move
  `Pixelvisor.app` to Applications and open it. The app is not notarised: on first launch,
  right-click it and choose *Open*, or allow it under System Settings → Privacy & Security.
  It lives in the menu bar and finds the bar automatically.
- **Anything else:** the [protocol](docs/protocol.md) is plain HTTP/JSON plus DDP over UDP.

### First settings

Open Settings in the web page or the app:

- **LED count** to match your strip (takes effect after *Reboot*).
- **Current limit** to your supply's rating minus 300 mA. The default, 1500 mA, is safe for
  most USB supplies and dims full white on long strips.
- **Reverse** if the first LED is at the right end. To check: `python3 tools/ddp_send.py
  pixelvisor.local --pattern index` lights the first LED red and the last blue.

## macOS app

Menu bar panel with power, brightness and four color sources: Color, White (2000–6500 K),
Effect and Mirror. Presets store a source with its values.

- **Follow monitor** sets the bar's brightness from your external monitor's brightness,
  read over DDC/CI. Needs Apple Silicon; does not work through most docks, DisplayLink
  adapters, or the HDMI port of M1 Macs.
- **Mirror** streams the colors along the top of a display to the bar. macOS asks for
  Screen Recording permission, and from macOS 15 it asks again from time to time.
- Turns the bar off on sleep and lock, and back on afterwards.

macOS asks for Local Network access on first launch; the app needs it to find the bar.

## Security

The bar trusts your local network: anyone on it can change the light, its settings and its
firmware, like most hobby LED controllers. Put it on a network you trust, or an IoT VLAN.

## Building from source

| Part | Command | Needs |
| --- | --- | --- |
| Firmware | `pio run`, `pio test -e native` | PlatformIO |
| macOS app | `apps/macos/build.sh test`, `apps/macos/build.sh app` | Xcode or the Command Line Tools (Swift 6) |
| Firmware update over WiFi | `pio run -e ota -t upload` | `curl` |

Development tools in `tools/` (Python 3, standard library only):

- `mock_device.py` — a fake bar for app development without hardware.
- `check_device.py <host>` — runs the protocol checks against a bar or the mock.
- `ddp_send.py <host> --pattern rainbow` — streams test patterns.

Protocol changes start in `protocol/fixtures/`, which the firmware tests, the app tests and
the mock all use. Details: [docs/firmware.md](docs/firmware.md),
[docs/macos-app.md](docs/macos-app.md).

## Releasing

Push a tag `vX.Y.Z`. The release workflow builds and tests everything, attaches the firmware
images and the macOS app to a GitHub release, and publishes the web flasher to GitHub Pages
(enable Pages with source *GitHub Actions* once in the repository settings).

## License

MIT, see [LICENSE](LICENSE). Third-party notices in [NOTICE](NOTICE).
