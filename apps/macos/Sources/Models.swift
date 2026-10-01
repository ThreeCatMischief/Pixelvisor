// Codable mirrors of docs/protocol.md. Unknown JSON keys are ignored; keys are snake_case
// on the wire and converted by the coders in PixelvisorAPI.

import Foundation

/// sRGB color, `[r, g, b]` on the wire.
struct RGB: Codable, Hashable, Sendable {
    var r: Int
    var g: Int
    var b: Int

    init(_ r: Int, _ g: Int, _ b: Int) {
        self.r = r
        self.g = g
        self.b = b
    }

    static let black = RGB(0, 0, 0)
    static let white = RGB(255, 255, 255)

    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        self.init(try c.decode(Int.self), try c.decode(Int.self), try c.decode(Int.self))
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(r)
        try c.encode(g)
        try c.encode(b)
    }
}

enum Mode: String, Codable, Sendable {
    case solid, effect
}

struct EffectState: Codable, Hashable, Sendable {
    var id: String
    var speed: Int
    var color2: RGB
}

struct RealtimeState: Codable, Hashable, Sendable {
    var active: Bool
    var source: String?
}

struct LightState: Codable, Hashable, Sendable {
    var rev: UInt32
    var on: Bool
    var brightness: Int
    var mode: Mode
    var color: RGB
    var effect: EffectState
    var realtime: RealtimeState

    /// The state after `patch`, for optimistic UI updates. The firmware response corrects it.
    func applying(_ patch: StatePatch) -> LightState {
        var s = self
        if let v = patch.on { s.on = v }
        if let v = patch.brightness { s.brightness = v }
        if let v = patch.mode { s.mode = v }
        if let v = patch.color { s.color = v }
        if let e = patch.effect {
            if let v = e.id { s.effect.id = v }
            if let v = e.speed { s.effect.speed = v }
            if let v = e.color2 { s.effect.color2 = v }
        }
        return s
    }
}

struct EffectPatch: Codable, Hashable, Sendable {
    var id: String?
    var speed: Int?
    var color2: RGB?
}

/// PATCH /api/state body. Nil fields are left out.
struct StatePatch: Codable, Hashable, Sendable {
    var on: Bool?
    var brightness: Int?
    var mode: Mode?
    var color: RGB?
    var effect: EffectPatch?
    var transitionMs: Int?

    /// Later values win, field by field.
    mutating func merge(_ other: StatePatch) {
        on = other.on ?? on
        brightness = other.brightness ?? brightness
        mode = other.mode ?? mode
        color = other.color ?? color
        transitionMs = other.transitionMs ?? transitionMs
        if let e = other.effect {
            var merged = effect ?? EffectPatch()
            merged.id = e.id ?? merged.id
            merged.speed = e.speed ?? merged.speed
            merged.color2 = e.color2 ?? merged.color2
            effect = merged
        }
    }
}

struct DeviceInfo: Codable, Hashable, Sendable {
    struct DDP: Codable, Hashable, Sendable {
        var port: Int
        var maxLeds: Int
    }

    var api: Int
    var fw: String
    var id: String
    var name: String
    var hostname: String
    var board: String
    var ledCount: Int
    var ip: String
    var rssi: Int
    var uptimeS: Int
    var freeHeap: Int
    var ddp: DDP
}

struct EffectInfo: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var name: String
    var uses: [String]

    func uses(_ parameter: String) -> Bool { uses.contains(parameter) }
}

struct DeviceConfig: Codable, Hashable, Sendable {
    var name: String
    var hostname: String
    var ledCount: Int
    var dataPin: Int
    var colorOrder: String
    var reverse: Bool
    var maxCurrentMa: Int
    var maPerChannel: Int
    var whiteBalance: RGB
    var gamma: Double
    var dither: Bool
    var powerOn: String
    var rebootRequired: Bool?

    static let colorOrders = ["RGB", "RBG", "GRB", "GBR", "BRG", "BGR"]
    static let powerOnOptions = ["restore", "on", "off"]
}

/// PATCH /api/config body. Nil fields are left out.
struct ConfigPatch: Codable, Hashable, Sendable {
    var name: String?
    var hostname: String?
    var ledCount: Int?
    var dataPin: Int?
    var colorOrder: String?
    var reverse: Bool?
    var maxCurrentMa: Int?
    var maPerChannel: Int?
    var whiteBalance: RGB?
    var gamma: Double?
    var dither: Bool?
    var powerOn: String?
}

/// Error body: `{"error": "...", "field": "..."}`.
struct APIErrorBody: Codable, Sendable {
    var error: String
    var field: String?
}

struct OkBody: Codable, Sendable {
    var ok: Bool
}
