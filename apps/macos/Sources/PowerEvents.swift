// Sleep, display sleep, lock and session switches, and what the app does about them.

import AppKit

enum PowerEvent: Sendable, CaseIterable {
    case willSleep, didWake, screensDidSleep, screensDidWake, locked, unlocked, sessionResigned, sessionActivated
}

/// Decides when to turn the strip off and back on. Several events fire for one sleep
/// (screens, then system); the strip goes off when the first reason appears and comes back
/// when the last one clears.
struct SleepCoordinator: Sendable {
    enum Reason: Sendable { case sleep, lock }
    enum Action: Equatable, Sendable { case turnOff, restore }

    var offOnSleep = true
    var offOnLock = true
    private(set) var reasons: Set<Reason> = []

    mutating func handle(_ event: PowerEvent) -> Action? {
        let before = reasons
        switch event {
        case .willSleep, .screensDidSleep: if offOnSleep { reasons.insert(.sleep) }
        case .didWake, .screensDidWake: reasons.remove(.sleep)
        case .locked, .sessionResigned: if offOnLock { reasons.insert(.lock) }
        case .unlocked, .sessionActivated: reasons.remove(.lock)
        }
        if before.isEmpty && !reasons.isEmpty { return .turnOff }
        if !before.isEmpty && reasons.isEmpty { return .restore }
        return nil
    }
}

/// Delivers PowerEvents from NSWorkspace and the screen lock notifications. Lives as long
/// as the app.
@MainActor
final class PowerEvents {
    private var tokens: [NSObjectProtocol] = []

    init(handler: @escaping @MainActor (PowerEvent) -> Void) {
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        let events: [(NotificationCenter, Notification.Name, PowerEvent)] = [
            (workspace, NSWorkspace.willSleepNotification, .willSleep),
            (workspace, NSWorkspace.didWakeNotification, .didWake),
            (workspace, NSWorkspace.screensDidSleepNotification, .screensDidSleep),
            (workspace, NSWorkspace.screensDidWakeNotification, .screensDidWake),
            (workspace, NSWorkspace.sessionDidResignActiveNotification, .sessionResigned),
            (workspace, NSWorkspace.sessionDidBecomeActiveNotification, .sessionActivated),
            (distributed, Notification.Name("com.apple.screenIsLocked"), .locked),
            (distributed, Notification.Name("com.apple.screenIsUnlocked"), .unlocked),
        ]
        for (center, name, event) in events {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { handler(event) }
            }
            tokens.append(token)
        }
    }
}
