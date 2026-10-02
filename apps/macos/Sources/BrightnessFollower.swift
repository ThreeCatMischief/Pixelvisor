// Follow monitor: the strip brightness tracks the external display's brightness setting,
// as MonitorControl last set it or, without MonitorControl, as read over DDC.

import CoreGraphics
import Foundation

struct BrightnessCurve: Codable, Hashable, Sendable {
    var floor = 0.05
    var ceiling = 1.0
    var gamma = 1.0

    /// Strip brightness 0-255 for a DDC reading. `level` is the panel slider, 0...1.
    func output(current: Int, max: Int, level: Double) -> Int {
        guard max > 0 else { return 0 }
        let m = min(Swift.max(Double(current) / Double(max), 0), 1)
        let curve = floor + (ceiling - floor) * pow(m, gamma)
        return Int(min(Swift.max((255 * curve * level).rounded(), 0), 255))
    }
}

struct FollowSettings: Codable, Hashable, Sendable {
    var displayUUID: String?  // nil: first external display
    var curve = BrightnessCurve()
    var level = 1.0
    var pollSeconds = 2.0
}

/// MonitorControl's stored brightness for a display. It saves the combined slider value
/// (0...1, DDC plus software dimming) as `value16(<name><vendor><model>@<display ID>)`.
/// Displays whose DDC cannot be read still have it, since MonitorControl only writes.
enum MonitorControlPrefs {
    private static var domain: CFString { "app.monitorcontrol.MonitorControl" as CFString }

    static func brightness(display: CGDirectDisplayID) -> Double? {
        CFPreferencesAppSynchronize(domain)
        guard let keys = CFPreferencesCopyKeyList(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String],
              let key = key(in: keys, vendor: CGDisplayVendorNumber(display), model: CGDisplayModelNumber(display), display: display)
        else { return nil }
        return (CFPreferencesCopyAppValue(key as CFString, domain) as? NSNumber)?.doubleValue
    }

    static func key(in keys: [String], vendor: UInt32, model: UInt32, display: CGDirectDisplayID) -> String? {
        let suffix = "\(vendor)\(model)@\(display))"
        return keys.first { $0.hasPrefix("value16(") && $0.hasSuffix(suffix) }
    }
}

enum FollowState: Equatable, Sendable {
    case idle
    case following(monitorPercent: Int, output: Int)
    case unavailable(DDCUnavailable)
    case paused
}

@MainActor @Observable
final class BrightnessFollower {
    private(set) var state: FollowState = .idle
    @ObservationIgnored var settings = FollowSettings()
    @ObservationIgnored var paused = false
    /// Sends a brightness with a transition in ms.
    @ObservationIgnored var apply: (Int, Int) -> Void = { _, _ in }

    @ObservationIgnored private let reader = DDCReader()
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var lastSent: Int?
    @ObservationIgnored private var reading: (current: Int, max: Int)?

    var isSupported: Bool { reader.isSupported }

    func start() {
        guard task == nil else { return }
        lastSent = nil
        task = Task { await run() }
    }

    func stop() {
        task?.cancel()
        task = nil
        state = .idle
    }

    func displaysChanged() {
        reader.reset()
    }

    /// The level slider applies at once, with a short transition.
    func levelChanged() {
        guard let reading else { return }
        let out = settings.curve.output(current: reading.current, max: reading.max, level: settings.level)
        state = .following(monitorPercent: percent(reading), output: out)
        lastSent = out
        apply(out, 150)
    }

    private func run() async {
        var failures = 0
        while !Task.isCancelled {
            if paused {
                state = .paused
                try? await Task.sleep(for: .seconds(1))
                continue
            }
            guard let display = Displays.display(uuid: settings.displayUUID) ?? Displays.external().first else {
                state = .unavailable(.noExternalDisplay)
                try? await Task.sleep(for: .seconds(5))
                continue
            }
            if let level = MonitorControlPrefs.brightness(display: display) {
                failures = 0
                follow((Int((min(max(level, 0), 1) * 1000).rounded()), 1000), transitionMs: 300)
                try? await Task.sleep(for: .milliseconds(500))  // a local read, cheap enough to poll fast
                continue
            }
            switch await reader.readBrightness(display: display) {
            case let .success(value):
                failures = 0
                follow(value, transitionMs: 800)
            case .failure(.noResponse):
                failures += 1
                if failures >= 3 {
                    state = .unavailable(.noResponse)
                    try? await Task.sleep(for: .seconds(30))
                    continue
                }
            case let .failure(reason):
                state = .unavailable(reason)
                try? await Task.sleep(for: .seconds(30))
                continue
            }
            try? await Task.sleep(for: .seconds(settings.pollSeconds))
        }
    }

    private func follow(_ value: (current: Int, max: Int), transitionMs: Int) {
        reading = value
        let out = settings.curve.output(current: value.current, max: value.max, level: settings.level)
        state = .following(monitorPercent: percent(value), output: out)
        if lastSent.map({ abs($0 - out) >= 2 }) ?? true {
            lastSent = out
            apply(out, transitionMs)
        }
    }

    private func percent(_ r: (current: Int, max: Int)) -> Int { Int((Double(r.current) / Double(r.max) * 100).rounded()) }
}
