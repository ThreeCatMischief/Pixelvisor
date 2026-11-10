// App-side preferences. Device state lives in the firmware; nothing here duplicates it.

import Foundation
import ServiceManagement

enum ColorSource: String, Codable, Sendable, CaseIterable, Identifiable {
    case color, white, effect, mirror

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum BrightnessSource: String, Codable, Sendable {
    case manual, followMonitor
}

/// A color source with its values. Applying it reproduces the light, not the brightness.
struct Preset: Codable, Hashable, Sendable, Identifiable {
    var id = UUID()
    var name: String
    var source: ColorSource
    var color: RGB?
    var kelvin: Int?
    var effect: EffectState?
}

struct DeviceSettings: Codable, Hashable, Sendable {
    var follow = FollowSettings()
    var mirror = MirrorSettings()
}

/// Preferences of one strip. Strips are controlled separately and share nothing here.
struct StripSettings: Codable, Hashable, Sendable {
    var lastColorSource = ColorSource.color
    var brightnessSource = BrightnessSource.manual
    var whiteKelvin = 4000
    var presets: [Preset] = []
}

struct AppSettings: Codable, Hashable, Sendable {
    /// Strips of the device, in firmware order: 0 Monitor, 1 Skadis.
    static let stripCount = 2
    static let maxPresets = 8
    private static let key = "settings.v1"

    var selectedDeviceID: String?
    var manualEndpoint: String?  // "192.168.1.42:80"
    var offOnSleep = true
    var offOnLock = true
    var strips = [StripSettings](repeating: StripSettings(), count: stripCount)
    /// Follow and mirror settings, keyed by device ID, or "<id>/<n>" for strip n > 0.
    var perDevice: [String: DeviceSettings] = [:]

    init() {}

    /// Reads every field optionally, so settings saved by older versions keep working. Before
    /// the second strip existed, the strip fields sat at the top level; they belong to strip 0.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        selectedDeviceID = try c.decodeIfPresent(String.self, forKey: .selectedDeviceID)
        manualEndpoint = try c.decodeIfPresent(String.self, forKey: .manualEndpoint)
        offOnSleep = try c.decodeIfPresent(Bool.self, forKey: .offOnSleep) ?? true
        offOnLock = try c.decodeIfPresent(Bool.self, forKey: .offOnLock) ?? true
        perDevice = try c.decodeIfPresent([String: DeviceSettings].self, forKey: .perDevice) ?? [:]
        if let strips = try c.decodeIfPresent([StripSettings].self, forKey: .strips) {
            self.strips = strips + [StripSettings](repeating: StripSettings(), count: max(Self.stripCount - strips.count, 0))
        } else {
            var first = StripSettings()
            first.lastColorSource = try c.decodeIfPresent(ColorSource.self, forKey: .lastColorSource) ?? first.lastColorSource
            first.brightnessSource = try c.decodeIfPresent(BrightnessSource.self, forKey: .brightnessSource) ?? first.brightnessSource
            first.whiteKelvin = try c.decodeIfPresent(Int.self, forKey: .whiteKelvin) ?? first.whiteKelvin
            first.presets = try c.decodeIfPresent([Preset].self, forKey: .presets) ?? []
            strips[0] = first
        }
    }

    private enum CodingKeys: String, CodingKey {
        case selectedDeviceID, manualEndpoint, offOnSleep, offOnLock, strips, perDevice
        case lastColorSource, brightnessSource, whiteKelvin, presets  // before strips existed
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(selectedDeviceID, forKey: .selectedDeviceID)
        try c.encodeIfPresent(manualEndpoint, forKey: .manualEndpoint)
        try c.encode(offOnSleep, forKey: .offOnSleep)
        try c.encode(offOnLock, forKey: .offOnLock)
        try c.encode(strips, forKey: .strips)
        try c.encode(perDevice, forKey: .perDevice)
    }

    static func load(from defaults: UserDefaults = .standard) -> AppSettings {
        guard let data = defaults.data(forKey: key),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else { return AppSettings() }
        return settings
    }

    func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.key) }
    }

    static func deviceKey(id: String, strip: Int) -> String { strip == 0 ? id : "\(id)/\(strip)" }

    subscript(device id: String?, strip strip: Int) -> DeviceSettings {
        get { id.flatMap { perDevice[Self.deviceKey(id: $0, strip: strip)] } ?? DeviceSettings() }
        set { if let id { perDevice[Self.deviceKey(id: id, strip: strip)] = newValue } }
    }
}

/// Launch at login through SMAppService; works only from the app bundle.
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ enabled: Bool) throws {
        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}
