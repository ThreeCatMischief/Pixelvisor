# macOS App Specification

A menu bar app that controls Pixelvisor over [protocol.md](protocol.md). It has no Dock
icon and no main window: a status bar icon opens a dropdown panel, and a separate Settings
window holds rarely used options.

## Requirements

| # | Requirement |
| --- | --- |
| M1 | Status bar icon with a dropdown panel: power, brightness, color, white temperature, effects, presets. |
| M2 | Finds devices automatically (Bonjour); manual IP as fallback. |
| M3 | **Follow monitor:** strip brightness tracks the external monitor's brightness setting, read via DDC/CI. |
| M4 | **Mirror screen:** strip colors follow the top of the screen (per-LED zones or one average color). |
| M5 | Brightness source (manual / follow monitor) and color source (color / white / effect / mirror) are independent. Follow monitor works together with mirroring. |
| M6 | Turns the strip off on display sleep, system sleep and screen lock; restores it afterwards. |
| M7 | Launch at login. |
| M8 | Device settings (name, LED count, current limit, color order, reverse, white balance), identify, reboot, firmware update. |
| M9 | Holds no device state of its own. The firmware is the source of truth; the app stores only app-side preferences. |
| M10 | Nothing personal in tracked files (Team ID, bundle prefix, IPs). |

## Platform

- macOS 14 (Sonoma) or later: `MenuBarExtra` window style, Observation (`@Observable`),
  `SMAppService`, ScreenCaptureKit.
- Swift 6 language mode, strict concurrency, SwiftUI with AppKit where SwiftUI falls short.
- **Follow monitor requires Apple Silicon.** DDC access uses `IOAVService`, which exists
  only on Apple Silicon. On Intel the feature is hidden.
- DDC also fails on some connection paths: the built-in HDMI port on M1 machines, many docks
  and hubs, and all DisplayLink adapters. The app detects this at runtime (see
  Follow monitor).
- The app is not sandboxed (IOKit/IOAVService access) and uses a private API. It cannot go
  on the Mac App Store. Distribution is direct download or build from source. The Hardened
  Runtime is enabled so the app can be notarised.

## Project layout

One Swift package, flat; no Xcode project. `build.sh` builds, tests and bundles it, so the
app builds with the Command Line Tools alone.

```
apps/macos/
├── Package.swift        # executable target Pixelvisor (Sources/), test target (Tests/)
├── build.sh             # ./build.sh test | app | run  →  build/Pixelvisor.app
├── Info.plist           # bundle template; build.sh fills in BUNDLE_ID and VERSION
├── Sources/             # PixelvisorApp, AppModel, PanelView, SettingsView, StatusIcon,
│                        # Models, PixelvisorAPI, PatchThrottler, Discovery, DDP, DDC,
│                        # BrightnessFollower, Mirror, PowerEvents, AppSettings, ColorMath
└── Tests/               # Swift Testing, against protocol/fixtures
```

Rule: views stay thin. Logic that can be tested without UI (parsing, throttling, curves,
mirror processing, sleep decisions) is in plain types that the tests import with
`@testable import Pixelvisor`.

### Signing and personal settings

`build.sh` reads `BUNDLE_ID` (default `org.example.pixelvisor`) and `SIGN_IDENTITY` (default
`-`, ad hoc) from the environment, so no personal value is in a tracked file. The bundle is
signed with the Hardened Runtime.

macOS ties the Screen Recording permission to the code signature. With ad hoc signing it
has to be granted again after every build; a stable identity (an Apple Development
certificate, or a self-signed code signing certificate from Keychain Access) avoids that.

### Info.plist keys

| Key | Value | Why |
| --- | --- | --- |
| `LSUIElement` | `YES` | No Dock icon |
| `NSLocalNetworkUsageDescription` | "Pixelvisor finds and controls your light on the local network." | Local Network privacy (macOS 15+) |
| `NSBonjourServices` | `["_pixelvisor._tcp"]` | Required for `NWBrowser` |
| `NSAppTransportSecurity` → `NSAllowsLocalNetworking` | `YES` | Plain HTTP to LAN addresses |

The Screen Recording prompt text comes from the system; no plist key applies.

## Architecture

```
                    ┌──────────────────────── AppModel (@Observable, @MainActor) ────────────────────────┐
 Panel / Settings ◀─┤ device, connection, firmwareState, colorSource, brightnessSource, presets, errors   │
   views (SwiftUI)  └──┬──────────────┬───────────────────┬────────────────────┬───────────────────┬────┘
                       │              │                   │                    │                   │
               DeviceBrowser   PixelvisorAPI (actor)  BrightnessFollower   MirrorEngine (actor)  PowerEvents
               (NWBrowser)     + PatchThrottler     DDC ─▶ Curve         ScreenSampler (SCK)   (NSWorkspace,
                                     │                   │ patch            ─▶ ZoneReducer        distributed
                                     │ HTTP             ─┘                  ─▶ Smoother           notifications)
                                     ▼                                      ─▶ DDPSender ── UDP ─▶ device
                                   device
```

### Components

**`Models`** (`Protocol/`). `Codable` structs mirroring protocol.md: `DeviceInfo`,
`LightState`, `StatePatch` (all fields optional, plus `transitionMs`), `DeviceConfig`,
`ConfigPatch`, `EffectInfo`, `RGB`. Unknown JSON keys are ignored. Decoding is tested
against `protocol/fixtures/`.

**`PixelvisorAPI`** (actor). One instance per selected device.
- `info()`, `state()`, `patch(_:)`, `effects()`, `config()`, `patchConfig(_:)`,
  `reboot()`, `identify()`, `uploadFirmware(_ url: URL, md5:, progress:)`.
- `URLSession` with an ephemeral configuration. Timeout 2 s (OTA 120 s).
- Errors map to `PixelvisorError`: `.unreachable`, `.http(status, message)`, `.decoding`,
  `.incompatibleAPI(version)`.

**`PatchThrottler`**. Sits in front of `patch`. At most one request in flight. While one is
in flight, new patches merge into a single pending patch; later values overwrite earlier
ones field by field. Minimum spacing is 100 ms, and the last value is always sent. Slider
patches carry `transitionMs = 150`, so the firmware interpolates between the 10 Hz updates.
Time source is injected for tests.

**`DeviceBrowser`**. `NWBrowser` for `.bonjourWithTXTRecord(type: "_pixelvisor._tcp",
domain: nil)`. Publishes `[DiscoveredDevice]` (`id`, `name`, `endpoint`, TXT fields).

**`DeviceResolver`**. Turns a Bonjour endpoint into `host:port`. It opens a short-lived
`NWConnection` to the endpoint and reads `currentPath.remoteEndpoint` when ready, preferring
IPv4. Results are cached per device `id` and invalidated on the first request failure,
which triggers re-resolve. A manual `host:port` from Settings bypasses Bonjour.

**`BrightnessFollower`**, **`DDC`**, **`BrightnessCurve`**: see Follow monitor.

**`MirrorEngine`**, **`ScreenSampler`**, **`ZoneReducer`**, **`Smoother`**, **`DDPSender`**:
see Mirror screen.

**`PowerEvents`**. Emits `.willSleep`, `.didWake`, `.screensDidSleep`, `.screensDidWake`,
`.locked`, `.unlocked`, `.sessionResigned`, `.sessionActivated`. Sources:
`NSWorkspace.shared.notificationCenter` and `DistributedNotificationCenter`
(`com.apple.screenIsLocked` / `com.apple.screenIsUnlocked`).

**`LoginItem`**. Wraps `SMAppService.mainApp` (`register`, `unregister`, `status`).

**`DisplayIdentity`**. Stable display key: `CGDisplayCreateUUIDFromDisplayID`. Display IDs
change across reboots and reconnects, so stored settings reference the UUID.

**`AppModel`** (`@Observable @MainActor`). Owns the services and the UI state. Holds a
copy of the last firmware state (`firmwareState`, `rev`) and applies optimistic updates:
the UI changes immediately, and the response or next poll corrects it.

### Settings storage

One `Codable` `AppSettings` value in `UserDefaults` under key `settings.v1`:

```swift
struct AppSettings: Codable {
    var selectedDeviceID: String?
    var manualEndpoint: String?            // "192.168.1.42:80"
    var launchAtLogin: Bool                // mirrors SMAppService status
    var offOnSleep: Bool = true
    var offOnLock: Bool = true
    var lastColorSource: ColorSource       // .color / .white / .effect / .mirror
    var brightnessSource: BrightnessSource // .manual / .followMonitor
    var whiteKelvin: Int = 4000
    var presets: [Preset]                  // up to 8
    var perDevice: [String: DeviceSettings] // keyed by device id
}

struct DeviceSettings: Codable {
    var follow: FollowSettings
    var mirror: MirrorSettings
}
```

A schema change adds a new key (`settings.v2`) with a one-time migration from the old one.

## UI

### Status icon

A custom template image, 18 × 18 pt. SF Symbols serve as a placeholder until it exists.
States:

| State | Icon |
| --- | --- |
| On | Filled bar with rays |
| Off | Outline bar |
| Mirroring | Filled bar with a small screen badge |
| No device / unreachable | Outline bar, slashed |

### Dropdown panel

`MenuBarExtra(...).menuBarExtraStyle(.window)`, fixed width 300 pt.

```
┌──────────────────────────────────────┐
│ Pixelvisor ● connected        [ ⏻ ]  │  name, status dot, power toggle
├──────────────────────────────────────┤
│ ☼ ─────────────●──────────  72 %     │  brightness
│   [ Manual | Follow monitor ]        │  brightness source
│   Following DELL U2723QE: 45 %       │  (only when following)
├──────────────────────────────────────┤
│ [ Color | White | Effect | Mirror ]  │  color source
│                                      │
│  (source-specific controls)          │
│                                      │
├──────────────────────────────────────┤
│ ● ● ● ● ● ● ● ●   + Save preset      │  presets (color source + values)
├──────────────────────────────────────┤
│ Settings…                     Quit   │
└──────────────────────────────────────┘
```

Source-specific controls:

| Source | Controls | Firmware effect |
| --- | --- | --- |
| Color | Hue bar and saturation bar (custom SwiftUI, inline) | `mode: solid`, `color` |
| White | Temperature slider 2000–6500 K with warm/cool ends | `mode: solid`, `color = kelvinToRGB(k)` |
| Effect | Effect picker from `/api/effects`; `color`, `color2`, `speed` shown per `uses` | `mode: effect`, `effect` |
| Mirror | Display picker, style (Zones / Average), start/stop state, permission prompt if needed | DDP stream |

Inline controls replace `ColorPicker`, whose system color panel opens as a separate floating
window and closes the dropdown.

Behaviour:

- Changes apply live through the `PatchThrottler`. There is no apply button.
- Brightness slider with source *Manual*: sets `brightness`. With *Follow monitor*: sets
  the follow **level** (0–100 %), a multiplier on the curve output. The label shows the
  resulting value.
- Selecting *Mirror* sets `on: true` if the strip is off, then starts the stream.
- Leaving *Mirror* stops the stream and sends a `PATCH` with the target `mode`, which ends
  realtime at once.
- Presets store a color source and its values (color, kelvin, effect with params, or
  mirror). Click applies; right-click offers Rename / Update / Delete.
- Disconnected: controls disabled. The panel shows "Looking for Pixelvisor…" or the
  error, plus a *Retry* button and a *Settings…* link.
- When the panel opens, the app runs `GET /api/state` and polls every 3 s while the panel
  stays open. If `rev` changed, it adopts the firmware state.

### Settings window

`Settings` scene with tabs. Opening it from a `MenuBarExtra` app needs
`NSApp.activate()` before `openSettings()`, otherwise the window opens behind other apps.

| Tab | Contents |
| --- | --- |
| General | Launch at login; turn off on sleep; turn off on lock |
| Device | Device list (discovered + manual entry); selected device info (fw, IP, RSSI, uptime); Identify; name; LED count; color order; reverse; current limit; white balance; power-on behaviour; Reboot; Update firmware…; Forget WiFi (confirmation; the device restarts into its setup network) |
| Brightness | Follow monitor: display, floor, ceiling, gamma, poll interval, live readout (monitor % → strip value), curve preview |
| Mirror | Display, style, band height, LED range covered by the screen, outside-range behaviour, saturation, smoothing, frame rate, live preview strip |
| About | Version, API version, links, licenses (including MonitorControl attribution) |

Device config edits send `PATCH /api/config`. If `reboot_required`, the tab shows a
"Reboot to apply" button.

Firmware update: pick a `.bin`, compute MD5, upload with a progress bar, then wait up to
30 s for the device to come back on Bonjour with the new `fw` version. Checking GitHub
releases for updates is deferred.

## Follow monitor

### DDC read (`DDC`)

Reads VCP code `0x10` (luminance) from an external display through `IOAVService`, the
approach used by MonitorControl
([`Arm64DDC.swift`](https://github.com/MonitorControl/MonitorControl), MIT). Adapt that code
with attribution rather than rediscovering the byte layout.

1. **Service matching.** Walk the IORegistry for `DCPAVServiceProxy` entries with
   `Location = External`. Match each one to a `CGDirectDisplayID` by EDID vendor, product
   and serial (`CGDisplayVendorNumber`, `CGDisplayModelNumber`, `CGDisplaySerialNumber`),
   falling back to the IORegistry order among external displays. Cache the mapping per
   display UUID and rebuild it on display reconfiguration
   (`CGDisplayRegisterReconfigurationCallback`).
2. **Request.** DDC/CI "Get VCP Feature" for `0x10`, sent with `IOAVServiceWriteI2C` to I²C
   address `0x37`. Wait 40 ms, then `IOAVServiceReadI2C` 11 bytes.
3. **Parse** (pure function, unit-tested with captured byte arrays): verify the checksum,
   result code and VCP code; extract `current` and `max`. Return `nil` on any mismatch.
4. **Retry:** up to 3 attempts, with a 50 ms gap. All DDC I/O runs on a dedicated serial
   queue, never on the main actor.

The private functions are declared with `@_silgen_name` and resolved at runtime. If a
symbol is missing, the feature reports `.unavailable(.unsupportedSystem)`.

### Mapping (`BrightnessCurve`)

Pure function:

```
m      = current / max                          (0…1)
curve  = floor + (ceiling − floor) · m^gamma    (floor, ceiling in 0…1)
output = round(255 · curve · level)             (level = panel slider, 0…1)
```

Defaults: floor 0.05, ceiling 1.0, gamma 1.0, level 1.0.

### Loop (`BrightnessFollower`)

- Polls the selected display every 2 s (setting: 1–10 s).
- Sends `PATCH {"brightness": output, "transition_ms": 800}` when `output` differs from the
  last sent value by ≥ 2. The level slider applies immediately with transition 150.
- States: `.following(monitorPercent, output)`, `.unavailable(reason)`, `.paused` (strip
  off or display asleep).
- 3 consecutive failed reads switch to `.unavailable(.noResponse)` and retry every 30 s. The
  panel shows the reason; the brightness source stays on *Follow monitor*, so it recovers
  on its own.
- DDC reads report the monitor's hardware setting. Software dimming (MonitorControl's
  gamma or shade mode) is invisible to it.
- Brightness changes made by another client are overwritten at the next monitor change.
  While the app is set to *Follow monitor*, the app owns brightness.

## Mirror screen

### Capture (`ScreenSampler`)

ScreenCaptureKit stream on the selected display:

| Setting | Zones style | Average style |
| --- | --- | --- |
| Filter | `SCContentFilter(display:, excludingApplications: [], exceptingWindows: [])` | same |
| `sourceRect` | Top band: full width × `bandHeight` (default 15 % of display height) | Full display |
| Output size | `min(4 × span, 256)` × 8 px | 32 × 18 px |
| Pixel format | `kCVPixelFormatType_32BGRA`, `colorSpaceName = sRGB` | same |
| Frame interval | `1 / fps` (15 / 30 / 60, default 30) | same |
| Cursor | hidden | hidden |
| Queue depth | 3 | 3 |

`span` = number of LEDs the screen covers (see Mapping). The GPU does the downscale, so the
CPU handles only a few hundred pixels per frame.

Permission: `SCShareableContent.current` triggers the Screen Recording prompt. If it is
denied, the Mirror section shows a button that opens
`x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture`. macOS 15+
periodically asks the user to reconfirm capture permission for apps that capture without
the system picker. This is expected, and the README documents it.

### Processing (pure, unit-tested)

1. **`ZoneReducer`.** Splits the buffer width into `span` equal columns (or the whole
   buffer, for Average). It averages each column in linear light (sRGB → linear, mean,
   → sRGB), then applies a saturation boost in HSV (`s × saturation`, clamped; default
   1.3).
2. **Mapping.** Places the `span` colors at logical LEDs `ledStart…ledEnd` (default
   0…`led_count − 1`). LEDs outside the range get the nearest edge color (`extend`,
   default) or black (`off`). Average style fills the whole strip with one color.
3. **`Smoother`.** Per-channel exponential smoothing with time constant τ (default 120 ms,
   0 = off). `α = 1 − exp(−Δt/τ)` with the actual frame interval, so smoothing is
   independent of frame rate.
4. **`DDPSender`.** Encodes one packet (header `41 xx 0B 01 00000000 <len>`) and sends it
   over a UDP `NWConnection` to the device IP, port from TXT `ddp` (default 4048).
   Sequence number cycles 1–15.

### Engine (`MirrorEngine`)

- Starts capture and sends frames. ScreenCaptureKit delivers frames only when content
  changes, so a 1 s timer resends the last frame (protocol keepalive rule).
- Pauses on display sleep, lock or system sleep, and resumes on wake if mirroring was
  active.
- Polls `GET /api/state` every 2 s while active, including when the panel is closed. If two
  consecutive polls show `realtime.active == false` or a `realtime.source` other than this
  Mac, another client has taken over: stop, set color source to the firmware's mode, and show
  "Mirroring stopped by another device" in the panel.
- When the display is disconnected, stop and show the reason.
- Targets on Apple Silicon at 30 fps: < 3 % CPU, < 60 MB memory. Screen-to-LED latency
  < 100 ms.

## Sleep, lock and session handling

| Event | Action (if the matching setting is on) |
| --- | --- |
| `willSleep`, `screensDidSleep`, `locked`, `sessionResigned` | Remember `wasOn`, whether mirroring was active, and the `rev` after the patch. Stop mirroring. `PATCH {"on": false, "transition_ms": 1000}`. |
| `didWake`, `screensDidWake`, `unlocked`, `sessionActivated` | If `wasOn` and the device `rev` still equals the remembered one: `PATCH {"on": true}` and resume mirroring. If `rev` changed, another client changed the state, so leave it. |

Several events fire for one sleep (screens sleep, then system sleep). The handler is
idempotent: it acts on the first "off" event and the matching first "on" event. After wake,
network requests are retried for up to 10 s while WiFi reconnects.

## Error handling

| Situation | Behaviour |
| --- | --- |
| No device found in 5 s | Panel: "Looking for Pixelvisor…", Settings link for manual IP |
| Request fails | Re-resolve once, retry once, then show disconnected. Retry discovery with backoff 1 → 2 → 5 → 10 s (max). |
| Device `api` > 1 | Disconnected with "Firmware is newer than this app. Update the app." |
| HTTP 400 on patch | Log it, re-fetch state, show a transient inline error |
| DDC unavailable | Follow monitor shows the reason; manual brightness keeps working |
| Screen Recording denied | Mirror shows the permission button; other sources keep working |

Logging: `os.Logger` with subsystem = bundle ID and categories `api`, `discovery`, `ddc`,
`mirror`, `power`.

## Testing

`apps/macos/build.sh test` runs without Xcode and without hardware.

| Test | Covers |
| --- | --- |
| `ModelDecodingTests` | All `protocol/fixtures/*.json` decode; round-trip of patches |
| `DDPEncoderTests` | Encoded packets byte-equal to `ddp_*.bin` fixtures; sequence wrap |
| `PatchThrottlerTests` | Merge semantics, 100 ms spacing, last value always sent (virtual clock) |
| `DDCParseTests` | Valid replies; checksum error; wrong VCP code; `max = 0` |
| `BrightnessCurveTests` | Endpoints, floor/ceiling, gamma, level |
| `ZoneReducerTests` | Synthetic buffers: solid, split halves, gradient; linear-light average (black + white ≠ 50 % grey sRGB) |
| `MappingTests` | LED range, extend/off, span 1, span = led_count |
| `SmootherTests` | τ = 0 passthrough; frame-rate independence (30 vs 60 fps converge equally) |
| `KelvinTests` | Known reference points within tolerance |
| `PowerEventTests` | Event sequence → exactly one off and one on patch; `rev` guard |

App build: `apps/macos/build.sh app`; tests: `apps/macos/build.sh test`.

Manual checks per release, recorded in `docs/test-log.md`:

1. Fresh install: Local Network prompt, discovery, control.
2. Device power cycle while the panel is open: reconnects without user action.
3. Device IP change (DHCP): reconnects via re-resolve.
4. Follow monitor: change brightness on the monitor OSD; strip follows within 3 s.
5. Mirror: fullscreen video, 10 min; no stalls; CPU within target.
6. Lock screen, sleep, wake: strip off and back on; mirroring resumes.
7. While mirroring, `PATCH {"mode":"solid"}` from `curl`: the app stops mirroring and shows
   the notice.
