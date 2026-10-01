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

struct AppSettings: Codable, Hashable, Sendable {
    var selectedDeviceID: String?
    var manualEndpoint: String?  // "192.168.1.42:80"
    var offOnSleep = true
    var offOnLock = true
    var lastColorSource = ColorSource.color
    var brightnessSource = BrightnessSource.manual
    var whiteKelvin = 4000
    var presets: [Preset] = []
    var perDevice: [String: DeviceSettings] = [:]

    static let maxPresets = 8
    private static let key = "settings.v1"

    static func load(from defaults: UserDefaults = .standard) -> AppSettings {
        guard let data = defaults.data(forKey: key),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else { return AppSettings() }
        return settings
    }

    func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.key) }
    }

    subscript(device id: String?) -> DeviceSettings {
        get { id.flatMap { perDevice[$0] } ?? DeviceSettings() }
        set { if let id { perDevice[id] = newValue } }
    }
}

/// Launch at login through SMAppService; works only from the app bundle.
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ enabled: Bool) throws {
        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}
