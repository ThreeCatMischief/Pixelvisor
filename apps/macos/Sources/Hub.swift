// The strips of the device and what they share. Each strip has its own AppModel (state,
// connection, brightness, mirror, presets); the hub holds the settings file, the Bonjour
// browser and the system events, and tracks which strip the panel shows.

import AppKit

@MainActor @Observable
final class Hub {
    static let shared = Hub()
    /// Names shown until the device reports its own.
    static let defaultNames = ["Monitor", "Skadis"]

    var settings = AppSettings.load() { didSet { settings.save() } }
    var selected = 0

    let browser = DeviceBrowser()
    @ObservationIgnored private(set) lazy var models: [AppModel] = (0..<AppSettings.stripCount).map { AppModel(index: $0) }
    @ObservationIgnored private var power: PowerEvents?

    /// Strips that are switched on. The panel shows a tab for each when there is more than one.
    var visible: [AppModel] {
        let on = models.filter(\.isEnabled)
        return on.isEmpty ? models : on
    }

    /// The strip the panel shows: the chosen one, or the first enabled one if that was switched off.
    var current: Int { visible.contains { $0.index == selected } ? selected : visible[0].index }
    var model: AppModel { models[current] }

    /// The strip the Settings window edits. It lists disabled strips too, so they can be enabled.
    var settingsSelected = 0
    var settingsModel: AppModel { models[settingsSelected] }

    func start() {
        browser.start()
        power = PowerEvents { [weak self] event in self?.models.filter(\.isEnabled).forEach { $0.handle(event) } }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Hub.shared.models.forEach { $0.displaysChanged() } }
        }
        models.forEach { $0.start() }
    }

    func reconnectAll() {
        models.forEach { $0.reconnect() }
    }

    func panelOpened() {
        models.forEach { $0.panelOpened() }
    }

    func panelClosed() {
        models.forEach { $0.panelClosed() }
    }

    /// Menu bar icon: mirroring wins, then on, then off.
    var iconState: AppModel.IconState {
        let states = models.filter(\.isEnabled).map(\.iconState)
        for state in [AppModel.IconState.mirroring, .on, .off] where states.contains(state) { return state }
        return .unreachable
    }
}
