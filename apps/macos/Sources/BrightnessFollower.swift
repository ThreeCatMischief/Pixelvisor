// Follow monitor: the strip brightness tracks the external display's brightness setting.

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
            switch await reader.readBrightness(display: display) {
            case let .success(value):
                failures = 0
                reading = value
                let out = settings.curve.output(current: value.current, max: value.max, level: settings.level)
                state = .following(monitorPercent: percent(value), output: out)
                if lastSent.map({ abs($0 - out) >= 2 }) ?? true {
                    lastSent = out
                    apply(out, 800)
                }
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

    private func percent(_ r: (current: Int, max: Int)) -> Int { Int((Double(r.current) / Double(r.max) * 100).rounded()) }
}
