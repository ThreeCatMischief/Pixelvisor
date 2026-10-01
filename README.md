# Pixelvisor

A light strip for the top of your monitor that you control over WiFi.

## What is it?

Pixelvisor turns a small, cheap WiFi chip (an ESP32) and a strip of LEDs into a light bar
for your desk. Stick the strip to the back or top of your monitor, plug it in, and control
it from your phone, your browser or your Mac.

It can:

- glow in any color or shade of white,
- play gentle effects like breathing or a rainbow,
- copy the colors at the top of your screen (Mac app),
- dim and brighten along with your monitor (Mac app).

No account, no cloud, no app store. It runs entirely on your home network.

## Get started

You need an **ESP32-C3 SuperMini** board, a **WS2812B LED strip** and a **5 V power supply**,
connected together.

1. **Install the software.** Open the [web installer](https://threecatmischief.github.io/Pixelvisor/)
   in Chrome or Edge, plug the board into your computer with a USB cable, and click
   *Install*.
2. **Connect it to WiFi.** Power the light. On your phone, join the WiFi network called
   **Pixelvisor-xxxxxx**. A setup page opens. Pick your home WiFi, enter the password, tap
   *Connect*.
3. **Use it.** Open <http://pixelvisor.local> in any browser on the same WiFi. On a Mac,
   you can also install the [menu bar app](https://github.com/ThreeCatMischief/Pixelvisor/releases).

That's it. The rest of this page is reference material.

---

## Features

- Solid colors, white temperatures (2000–6500 K) and effects (breathe, rainbow, gradient,
  scan), with smooth fades.
- Restores its last state after a power cut; works without a network.
- WiFi setup from your phone: no credentials in the firmware, no tools needed.
- Firmware updates from the web page.
- Open HTTP/JSON API and the public DDP protocol, so other tools (xLights, LedFx, WLED
  senders, scripts) can drive it too. See [docs/protocol.md](docs/protocol.md).

## Hardware

| Part | Notes |
| --- | --- |
| ESP32-C3 SuperMini | Or a classic ESP32 dev board (ESP32-WROOM-32). |
| WS2812B strip, 5 V, 60 LEDs/m | 720 mm = 43 LEDs. Any length up to 480 LEDs works; set the LED count in Settings. |
| 5 V supply | About 60 mA per LED at full white. A 3 A supply covers 43 LEDs. |

The strip's data line goes to GPIO 4 (classic ESP32: GPIO 16).

## Other ways to install the firmware

**With PlatformIO.** Install [PlatformIO](https://platformio.org) (the VS Code extension
or `pip install platformio`), then from this folder:

```sh
pio run -t upload                 # ESP32-C3 SuperMini
pio run -e esp32dev -t upload     # classic ESP32
```

**With esptool.** Download `pixelvisor-esp32c3-<version>-factory.bin` (or `-esp32-`) from
the [releases page](https://github.com/ThreeCatMischief/Pixelvisor/releases) and run
`esptool.py write_flash 0x0 pixelvisor-…-factory.bin`.

## WiFi setup details

- With no WiFi configured, the first three LEDs breathe blue.
- If the setup page does not open by itself, open <http://192.168.4.1> while connected to
  the **Pixelvisor-xxxxxx** network.
- If the bar cannot reach its network for 3 minutes, it opens the setup network again until
  you choose a new one. *Forget WiFi* in the web page or the app does the same at once.
- If `pixelvisor.local` does not resolve, use the bar's IP address from your router.

## First settings

Open Settings in the web page or the app:

- **LED count** to match your strip (takes effect after *Reboot*).
- **Current limit** to your supply's rating minus 300 mA. The default, 1500 mA, is safe for
  most USB supplies and dims full white on long strips.
- **Reverse** if the first LED is at the right end. To check: `python3 tools/ddp_send.py
  pixelvisor.local --pattern index` lights the first LED red and the last blue.

## macOS app

Download `Pixelvisor-macOS-<version>.zip` from the
[releases page](https://github.com/ThreeCatMischief/Pixelvisor/releases), unzip,
move `Pixelvisor.app` to Applications and open it. The app is not notarised: on first
launch, right-click it and choose *Open*, or allow it under System Settings → Privacy &
Security. macOS asks for Local Network access; the app needs it to find the bar.

Menu bar panel with power, brightness and four color sources: Color, White, Effect and
Mirror. Presets store a source with its values.

- **Follow monitor** sets the bar's brightness from your external monitor's brightness,
  read over DDC/CI. Needs Apple Silicon; does not work through most docks, DisplayLink
  adapters, or the HDMI port of M1 Macs.
- **Mirror** streams the colors along the top of a display to the bar. macOS asks for
  Screen Recording permission, and from macOS 15 it asks again from time to time.
- Turns the bar off on sleep and lock, and back on afterwards.

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
images and the macOS app to a GitHub release, and publishes the web installer to GitHub
Pages (enable Pages with source *GitHub Actions* once in the repository settings).

## License

MIT, see [LICENSE](LICENSE). Third-party notices in [NOTICE](NOTICE).
