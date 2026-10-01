# Device Protocol (API v1)

The contract between the firmware and every client (macOS app, Windows app, mock device,
third-party tools). Clients depend only on this document, not on firmware internals.

Two channels:

| Channel | Transport | Port | Use |
| --- | --- | --- | --- |
| Control | HTTP/1.1, JSON | 80 | State, config, effects, info, maintenance |
| Realtime | UDP, DDP | 4048 | Per-LED frames (screen mirroring, external tools) |

The device trusts the local network. There is no authentication in v1 (see
[Security](#security)).

## Discovery

The device advertises `_http._tcp` (for browsers) and this service:

- Service type: `_pixelvisor._tcp`, port 80
- Instance name: the device `name` (default `Pixelvisor`)
- Hostname: `<hostname>.local` (default `pixelvisor`)
- TXT records:

| Key | Example | Meaning |
| --- | --- | --- |
| `id` | `a1b2c3` | Device ID: last 3 bytes of the WiFi MAC, lowercase hex. Stable across renames. |
| `api` | `1` | API major version |
| `fw` | `0.1.0` | Firmware version (SemVer) |
| `leds` | `43` | Configured LED count |
| `ddp` | `4048` | Realtime UDP port |

Clients identify a device by `id`, not by name, hostname or IP. Clients resolve the service
to an IP address and port and use those for all requests; `.local` lookups per request are
slow. Clients take the port from the service record and do not assume 80 (the mock device
uses 8080).

## LED indexing

Logical index 0 is the **leftmost** LED as seen from the front. This applies to realtime
frames, effects and `led_count`. When the strip is mounted with its first LED at the right
end, the `reverse` config flag maps logical to physical order on the device. Clients never
reverse.

## Versioning

- `api` increments only on breaking changes. Clients refuse devices with a higher major
  version and show "firmware newer than app".
- Additive changes (new fields, new endpoints, new effects) do not change `api`.
- Clients ignore unknown JSON fields. The firmware ignores unknown request fields.

## Conventions

- Request and response bodies are `application/json`, UTF-8.
- Colors are `[r, g, b]` arrays, 0–255, sRGB (gamma-encoded, as a color picker produces).
  The firmware applies gamma correction and white balance before output. Clients never
  pre-correct.
- Brightness is 0–255 and acts as a master scaler on every color source, including
  realtime frames.
- Errors: HTTP 400 for validation failures, 404 for unknown paths, 409 for requests invalid
  in the current device state, 500 for internal failures. Body:
  `{"error": "brightness out of range", "field": "brightness"}` (`field` optional).

## Control API

### `GET /api/info`

Static and diagnostic information.

```json
{
  "api": 1,
  "fw": "0.1.0",
  "id": "a1b2c3",
  "name": "Pixelvisor",
  "hostname": "pixelvisor",
  "board": "esp32c3",
  "led_count": 43,
  "ip": "192.168.1.42",
  "rssi": -54,
  "uptime_s": 86400,
  "free_heap": 182000,
  "ddp": { "port": 4048, "max_leds": 480 }
}
```

### `GET /api/state`

```json
{
  "rev": 118,
  "on": true,
  "brightness": 180,
  "mode": "solid",
  "color": [255, 170, 90],
  "effect": { "id": "breathe", "speed": 128, "color2": [0, 0, 0] },
  "realtime": { "active": false, "source": null }
}
```

| Field | Type | Writable | Notes |
| --- | --- | --- | --- |
| `rev` | uint32 | no | Increments when a PATCH changes a writable field, and is kept across reboots. Realtime start and end do not change it. Clients compare it to detect changes made by other clients. |
| `on` | bool | yes | Off fades to black; all other state is kept. |
| `brightness` | 0–255 | yes | Master brightness. 0 is allowed and means black while `on`. |
| `mode` | `"solid"` \| `"effect"` | yes | Color source when no realtime stream is active. |
| `color` | `[r,g,b]` | yes | Used by `solid`, and as the primary color by effects. |
| `effect.id` | string | yes | One of the IDs from `GET /api/effects`. |
| `effect.speed` | 0–255 | yes | Effect-specific; 128 is the default. |
| `effect.color2` | `[r,g,b]` | yes | Secondary color for effects that use one. |
| `realtime.active` | bool | no | True while DDP frames are arriving. |
| `realtime.source` | string \| null | no | Sender IP of the active stream. |

### `PATCH /api/state`

Partial update. Any subset of the writable fields, plus one request-only field:

| Field | Type | Default | Notes |
| --- | --- | --- | --- |
| `transition_ms` | 0–10000 | 400 | Crossfade duration for this change. Not stored. |

```json
{ "brightness": 90, "transition_ms": 150 }
```

Response: the full state (same shape as `GET /api/state`) after the change is applied.

Rules:

- Validation is all-or-nothing. If any field is invalid, nothing changes and the device
  returns 400.
- A PATCH that contains `mode` ends an active realtime stream immediately and ignores that
  stream's sender until it has sent nothing for 1 s. Without the block, frames still in
  flight would restart the stream; a sender that keeps streaming stays blocked, so a
  takeover by another client sticks. A client that ends its own stream and wants to start
  again waits 1 s after its last frame. A PATCH without `mode` (for example brightness
  only) does not affect realtime.
- Writes are persisted to flash 5 s after the last change (see firmware spec). Clients do
  not need to do anything to persist.

### `GET /api/effects`

Lists the effects the firmware supports and their parameters, so clients can build
controls without hardcoding the list.

```json
[
  { "id": "breathe",  "name": "Breathe",  "uses": ["color", "speed"] },
  { "id": "rainbow",  "name": "Rainbow",  "uses": ["speed"] },
  { "id": "gradient", "name": "Gradient", "uses": ["color", "color2"] },
  { "id": "scan",     "name": "Scan",     "uses": ["color", "color2", "speed"] }
]
```

`uses` lists which of `color`, `color2`, `speed` affect the effect. Clients show only those
controls.

### `GET /api/config` / `PATCH /api/config`

Hardware and device configuration. Changes here are rare and done from a settings screen.

```json
{
  "name": "Pixelvisor",
  "hostname": "pixelvisor",
  "led_count": 43,
  "data_pin": 4,
  "color_order": "GRB",
  "reverse": false,
  "max_current_ma": 2500,
  "ma_per_channel": 20,
  "white_balance": [255, 224, 200],
  "gamma": 2.2,
  "dither": true,
  "power_on": "restore"
}
```

| Field | Type | Reboot | Notes |
| --- | --- | --- | --- |
| `name` | string, 1–32 characters, at most 63 bytes of UTF-8 | no | Display name and mDNS instance name. |
| `hostname` | `[a-z0-9-]{1,24}` | yes | mDNS hostname. |
| `led_count` | 1–480 | yes | 480 is the DDP single-packet limit. |
| `data_pin` | GPIO number | yes | Validated against a per-board allowlist. |
| `color_order` | `RGB` `RBG` `GRB` `GBR` `BRG` `BGR` | no | WS2812B is `GRB`. |
| `reverse` | bool | no | Set when the physical first LED is at the right end. See [LED indexing](#led-indexing). |
| `max_current_ma` | 100–20000, or 0 | no | Current limit; 0 disables limiting. |
| `ma_per_channel` | 1–60 | no | Current estimate per channel at full value. |
| `white_balance` | `[r,g,b]` | no | Per-channel scale applied after gamma. Corrects the blue tint of WS2812B white. |
| `gamma` | 1.0–3.0 | no | Output gamma exponent. |
| `dither` | bool | no | Temporal dithering at low brightness. |
| `power_on` | `"restore"` \| `"on"` \| `"off"` | no | Behaviour after power loss. |

`GET` and `PATCH /api/config` respond with the full config plus
`"reboot_required": true|false`. Fields that require a reboot are saved and reported with
their new value, but take effect only after `POST /api/reboot`.

### `POST /api/reboot`

Responds 202 `{"ok": true}`, then restarts after 500 ms.

### `POST /api/identify`

Flashes the strip white three times (about 1.5 s total), then returns to the current state.
Responds 202 `{"ok": true}`. Used by settings screens to confirm which device is selected.

### WiFi setup

The device stores its WiFi credentials in flash. Without credentials, or when it cannot
reach its network (30 s after boot, or 3 min after losing it), it opens the open setup
network `Pixelvisor-<id>` at `192.168.4.1` and keeps retrying its network in the
background. While the setup network is open, `GET /` serves the setup page and other
non-API paths redirect to it, so phones show it as a captive portal.

#### `GET /api/wifi/scan`

Networks in range, strongest first. Takes a few seconds.

```json
[ { "ssid": "Home", "rssi": -48, "secure": true } ]
```

#### `POST /api/wifi`

`{"ssid": "Home", "password": "…"}`. `ssid` 1–32 bytes; `password` empty (open network) or
8–63 characters. Stores the credentials, responds 202 `{"ok": true}` and restarts to join
the network.

#### `DELETE /api/wifi`

Forgets the stored credentials, responds 202 `{"ok": true}` and restarts into the setup
network.

### `POST /api/ota`

Firmware update. Body: the raw application image (`firmware.bin`) as
`application/octet-stream`, with `Content-Length` set. Optional header
`X-Firmware-MD5: <32 hex chars>`: when present, the device rejects an image whose MD5 does not
match.

- Responds 200 `{"ok": true}` after the image is written and verified, then reboots.
- Responds 400 if the image header is invalid, 409 if an update is already running.
- During the upload the strip shows a progress bar (see firmware spec, status display).

## Realtime: DDP

[DDP (Distributed Display Protocol)](http://www.3waylabs.com/ddp/) over UDP, port 4048.
Using a public protocol means existing tools (xLights, WLED senders, LedFx) can drive the
bar, and the bar can be tested without the app.

### Packet layout

| Offset | Size | Field | Value |
| --- | --- | --- | --- |
| 0 | 1 | Flags | `0x41` = version 1 + PUSH. Bits: `VV x T S R Q P`. |
| 1 | 1 | Sequence | Low 4 bits, 1–15 wrapping; 0 = unused. |
| 2 | 1 | Data type | `0x0B` = RGB, 8 bit per channel. |
| 3 | 1 | Destination | `1` = default output. |
| 4 | 4 | Offset | Byte offset into the frame, big-endian. |
| 8 | 2 | Length | Payload length in bytes, big-endian. |
| 10 | n | Payload | `r g b r g b …` |

If the T (timecode) flag is set, 4 timecode bytes follow the header and the payload starts
at offset 14. The firmware skips them.

### Receiver rules (firmware)

- Reject packets whose version bits are not `01`.
- Accept data types `0x00`, `0x01` and `0x0B` as RGB24; drop other types.
- Accept destinations `1` and `255`; drop others.
- Write the payload to the frame buffer at `offset`. Bytes beyond `led_count * 3` are
  dropped.
- Show the frame when a packet with PUSH arrives. Senders with ≤ 480 LEDs send one packet
  per frame with PUSH set.
- Sequence numbers are informational. The receiver does not reorder or drop by sequence.
- Frames are ignored while `on` is false. They do not turn the strip on.
- Realtime starts on the first accepted frame. The strip crossfades into it over 150 ms.
- Realtime ends 2.5 s after the last accepted frame, or at once on a `PATCH` containing
  `mode`. The strip crossfades back to the stored mode over 400 ms.
- With multiple senders, the most recent sender wins. `realtime.source` reports it.
- Realtime frames are never persisted.

### Sender rules (clients)

- Send the full strip each frame: offset 0, `led_count * 3` bytes, PUSH set.
- Send colors in logical order (index 0 = leftmost LED). The device applies `reverse`.
- When the source image does not change, repeat the last frame at least once per second.
  This keeps the stream from timing out.
- Stop sending to end the stream, or `PATCH` `mode` to end it immediately.

## Security

v1 has no authentication. Anyone on the LAN can change state, config, WiFi and firmware.
This matches most hobby LED firmware (WLED, Tasmota defaults) and is documented in the
public README. Put the device on a trusted network or an IoT VLAN.

Possible later addition, reserved now: an optional `X-Pixelvisor-Token` header, required only
when a token is set in config. Clients should already send it when the user has configured
one.

## Shared fixtures

`protocol/fixtures/` at the repo root holds canonical samples, all JSON:

- `info.json`, `state.json`, `config.json`, `effects.json`: valid responses. `state.json`,
  `config.json` and `effects.json` are exactly what the firmware sends with its defaults.
- `state_patches.json`, `config_patches.json`: request bodies with the expected outcome
  (`valid`, the rejected `field`, expected values, `reboot_required`).
- `ddp.json`: packets as hex, with whether the device shows them and the resulting frame.

The firmware native tests, macOS tests, Windows tests and the mock device all load these
fixtures. A protocol change starts with a fixture change.
