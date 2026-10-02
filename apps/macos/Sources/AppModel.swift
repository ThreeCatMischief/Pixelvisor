// UI state and wiring. The firmware is the source of truth: the model keeps the last state
// it reported, applies changes optimistically, and adopts each response.

import AppKit
import os

@MainActor @Observable
final class AppModel {
    static let shared = AppModel()

    enum Connection: Equatable {
        case searching   // nothing found yet
        case connecting
        case connected
        case failed(String)
    }

    enum Upload: Equatable {
        case uploading(Double)
        case restarting
        case done(String)
        case failed(String)
    }

    enum IconState {
        case on, off, mirroring, unreachable
    }

    var settings = AppSettings.load() { didSet { settings.save() } }
    let browser = DeviceBrowser()
    let follower = BrightnessFollower()

    private(set) var connection = Connection.searching
    private(set) var endpoint: Endpoint?
    private(set) var info: DeviceInfo?
    private(set) var state: LightState?
    private(set) var effects: [EffectInfo] = []
    private(set) var config: DeviceConfig?
    private(set) var colorSource = ColorSource.color
    private(set) var mirroring = false
    private(set) var mirrorPreview: [RGB] = []
    private(set) var mirrorMessage: String?
    private(set) var notice: String?
    private(set) var upload: Upload?
    /// Panel color bars; kept separately so hue survives a fully desaturated color.
    var hue = 0.07
    var saturation = 0.65

    @ObservationIgnored private var api: PixelvisorAPI?
    @ObservationIgnored private lazy var throttler = PatchThrottler { [weak self] patch in await self?.send(patch) }
    @ObservationIgnored private let mirror = MirrorEngine()
    @ObservationIgnored private var power: PowerEvents?
    @ObservationIgnored private var sleep = SleepCoordinator()
    @ObservationIgnored private var stripDisplayOnline = true
    @ObservationIgnored private var sleepRecord: (wasOn: Bool, wasMirroring: Bool, rev: UInt32?)?
    @ObservationIgnored private var connectTask: Task<Void, Never>?
    @ObservationIgnored private var panelPoll: Task<Void, Never>?
    @ObservationIgnored private var mirrorPoll: Task<Void, Never>?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "pixelvisor", category: "api")

    // MARK: - Lifecycle

    func start() {
        browser.start()
        power = PowerEvents { [weak self] event in self?.handle(event) }
        follower.apply = { [weak self] brightness, ms in self?.submit(StatePatch(brightness: brightness, transitionMs: ms)) }
        mirror.onPreview = { colors in Task { @MainActor in AppModel.shared.mirrorPreview = colors } }
        mirror.onStopped = { reason in Task { @MainActor in AppModel.shared.mirrorStopped("Mirroring stopped: \(reason)") } }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                AppModel.shared.follower.displaysChanged()
                AppModel.shared.checkStripDisplay()
            }
        }
        connect()
        checkStripDisplay()
    }

    var deviceSettings: DeviceSettings {
        get { settings[device: info?.id] }
        set { settings[device: info?.id] = newValue }
    }

    var iconState: IconState {
        guard connection == .connected, let state else { return .unreachable }
        if mirroring { return .mirroring }
        return state.on ? .on : .off
    }

    var deviceName: String { info?.name ?? "Pixelvisor" }

    // MARK: - Connection

    /// Finds the device and attaches to it, retrying with backoff 1, 2, 5, 10 s.
    func connect() {
        connectTask?.cancel()
        api = nil
        if connection == .connected { connection = .connecting }
        connectTask = Task {
            let started = ContinuousClock.now
            var attempt = 0
            while !Task.isCancelled {
                if let target = await locate() {
                    do {
                        try await attach(target)
                        return
                    } catch {
                        connection = .failed(error.localizedDescription)
                    }
                } else if ContinuousClock.now - started > .seconds(5) {
                    connection = .searching
                }
                try? await Task.sleep(for: .seconds([1, 2, 5, 10][min(attempt, 3)]))
                attempt += 1
            }
        }
    }

    private func locate() async -> Endpoint? {
        if let manual = settings.manualEndpoint, let endpoint = Endpoint(manual) { return endpoint }
        let devices = browser.devices
        guard let device = devices.first(where: { $0.id == settings.selectedDeviceID }) ?? devices.first else { return nil }
        return try? await DeviceResolver.resolve(device.endpoint)
    }

    private func attach(_ endpoint: Endpoint) async throws {
        let api = PixelvisorAPI(endpoint: endpoint)
        let info = try await api.info()
        let state = try await api.state()
        let effects = try await api.effects()
        self.api = api
        self.endpoint = endpoint
        self.info = info
        self.effects = effects
        if settings.manualEndpoint == nil { settings.selectedDeviceID = info.id }
        adopt(state)
        connection = .connected
        follower.settings = deviceSettings.follow
        if settings.brightnessSource == .followMonitor { follower.start() }
        Self.log.info("connected to \(info.name, privacy: .public) at \(endpoint, privacy: .public)")
    }

    /// Runs a request. On a network failure it re-resolves once and retries once; after
    /// that the panel shows disconnected and discovery starts over.
    private func call<T: Sendable>(_ request: (PixelvisorAPI) async throws -> T) async throws -> T {
        guard let api else { throw PixelvisorError.unreachable }
        do {
            return try await request(api)
        } catch PixelvisorError.unreachable {
            if let endpoint = await locate() {
                let retry = PixelvisorAPI(endpoint: endpoint)
                if let result = try? await request(retry) {
                    self.api = retry
                    self.endpoint = endpoint
                    return result
                }
            }
            connection = .failed(PixelvisorError.unreachable.localizedDescription)
            connect()
            throw PixelvisorError.unreachable
        }
    }

    func useDevice(id: String) {
        settings.manualEndpoint = nil
        settings.selectedDeviceID = id
        reconnect()
    }

    func useManualEndpoint(_ text: String) -> Bool {
        guard Endpoint(text) != nil else { return false }
        settings.manualEndpoint = text
        reconnect()
        return true
    }

    private func reconnect() {
        stopMirror()
        follower.stop()
        info = nil
        state = nil
        config = nil
        connection = .connecting
        connect()
    }

    // MARK: - State

    private func adopt(_ s: LightState) {
        state = s
        follower.paused = !s.on || !sleep.reasons.isEmpty
        guard !mirroring else { return }
        if s.mode == .effect {
            colorSource = .effect
        } else if settings.lastColorSource == .white && s.color == ColorMath.kelvin(settings.whiteKelvin) {
            colorSource = .white
        } else {
            colorSource = .color
            if s.color != ColorMath.color(hue: hue, saturation: saturation) {
                (hue, saturation) = ColorMath.hueSaturation(s.color)
            }
        }
    }

    /// Applies `patch` to the UI at once and sends it through the throttler.
    func submit(_ patch: StatePatch) {
        guard let state else { return }
        self.state = state.applying(patch)
        throttler.submit(patch)
    }

    private func send(_ patch: StatePatch) async {
        do {
            let s = try await call { try await $0.patch(patch) }
            if !throttler.hasPending { adopt(s) }
        } catch let PixelvisorError.http(_, message) {
            Self.log.error("patch rejected: \(message, privacy: .public)")
            show(notice: message)
            await refresh()
        } catch {}
    }

    func refresh() async {
        guard connection == .connected, !throttler.hasPending, let s = try? await call({ try await $0.state() }) else { return }
        if !throttler.hasPending { adopt(s) }
    }

    func panelOpened() {
        panelPoll?.cancel()
        panelPoll = Task {
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    func panelClosed() {
        panelPoll?.cancel()
        panelPoll = nil
    }

    private func show(notice text: String) {
        notice = text
        noticeTask?.cancel()
        noticeTask = Task {
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { notice = nil }
        }
    }

    // MARK: - Panel controls

    func togglePower() {
        guard let state else { return }
        submit(StatePatch(on: !state.on))
    }

    /// The slider: brightness with Manual, the follow level with Follow monitor.
    var brightnessLevel: Double {
        if settings.brightnessSource == .followMonitor { return deviceSettings.follow.level }
        return Double(state?.brightness ?? 0) / 255
    }

    func setBrightnessLevel(_ level: Double) {
        if settings.brightnessSource == .followMonitor {
            deviceSettings.follow.level = level
            follower.settings = deviceSettings.follow
            follower.levelChanged()
        } else {
            submit(StatePatch(brightness: Int((level * 255).rounded()), transitionMs: 150))
        }
    }

    func setBrightnessSource(_ source: BrightnessSource) {
        settings.brightnessSource = source
        if source == .followMonitor {
            follower.settings = deviceSettings.follow
            follower.start()
        } else {
            follower.stop()
        }
    }

    func followSettingsChanged(_ follow: FollowSettings) {
        deviceSettings.follow = follow
        follower.settings = follow
        follower.levelChanged()
    }

    func select(_ source: ColorSource) {
        guard source != colorSource else { return }
        if colorSource == .mirror { stopMirror() }
        colorSource = source
        switch source {
        case .color:
            settings.lastColorSource = .color
            submit(StatePatch(mode: .solid, color: ColorMath.color(hue: hue, saturation: saturation)))
        case .white:
            settings.lastColorSource = .white
            submit(StatePatch(mode: .solid, color: ColorMath.kelvin(settings.whiteKelvin)))
        case .effect:
            settings.lastColorSource = .effect
            submit(StatePatch(mode: .effect))
        case .mirror:
            startMirror()
        }
    }

    func setColor(hue: Double, saturation: Double) {
        self.hue = hue
        self.saturation = saturation
        submit(StatePatch(mode: .solid, color: ColorMath.color(hue: hue, saturation: saturation), transitionMs: 150))
    }

    func setKelvin(_ kelvin: Int) {
        settings.whiteKelvin = kelvin
        submit(StatePatch(mode: .solid, color: ColorMath.kelvin(kelvin), transitionMs: 150))
    }

    func setEffect(_ effect: EffectPatch, transitionMs: Int? = nil) {
        submit(StatePatch(mode: .effect, effect: effect, transitionMs: transitionMs))
    }

    func setEffectColor(_ color: RGB) {
        submit(StatePatch(mode: .effect, color: color, transitionMs: 150))
    }

    var currentEffect: EffectInfo? { effects.first { $0.id == state?.effect.id } }

    // MARK: - Presets

    func savePreset() {
        guard let state, settings.presets.count < AppSettings.maxPresets else { return }
        var preset = Preset(name: "", source: colorSource)
        fill(&preset, from: state)
        settings.presets.append(preset)
    }

    func updatePreset(_ id: UUID) {
        guard let state, let i = settings.presets.firstIndex(where: { $0.id == id }) else { return }
        let name = settings.presets[i].name
        settings.presets[i] = Preset(id: id, name: "", source: colorSource)
        fill(&settings.presets[i], from: state)
        settings.presets[i].name = name
    }

    func renamePreset(_ id: UUID, to name: String) {
        guard let i = settings.presets.firstIndex(where: { $0.id == id }), !name.isEmpty else { return }
        settings.presets[i].name = name
    }

    func deletePreset(_ id: UUID) {
        settings.presets.removeAll { $0.id == id }
    }

    private func fill(_ preset: inout Preset, from state: LightState) {
        switch preset.source {
        case .color:
            preset.color = state.color
            preset.name = "Color"
        case .white:
            preset.kelvin = settings.whiteKelvin
            preset.name = "\(settings.whiteKelvin) K"
        case .effect:
            preset.effect = state.effect
            preset.color = state.color
            preset.name = currentEffect?.name ?? state.effect.id
        case .mirror:
            preset.name = "Mirror"
        }
    }

    func apply(_ preset: Preset) {
        if colorSource == .mirror && preset.source != .mirror { stopMirror() }
        switch preset.source {
        case .color:
            guard let color = preset.color else { return }
            colorSource = .color
            settings.lastColorSource = .color
            (hue, saturation) = ColorMath.hueSaturation(color)
            submit(StatePatch(mode: .solid, color: color))
        case .white:
            colorSource = .white
            settings.lastColorSource = .white
            settings.whiteKelvin = preset.kelvin ?? settings.whiteKelvin
            submit(StatePatch(mode: .solid, color: ColorMath.kelvin(settings.whiteKelvin)))
        case .effect:
            guard let e = preset.effect else { return }
            colorSource = .effect
            settings.lastColorSource = .effect
            submit(StatePatch(mode: .effect, color: preset.color, effect: EffectPatch(id: e.id, speed: e.speed, color2: e.color2)))
        case .mirror:
            select(.mirror)
        }
    }

    /// Swatch color for a preset in the panel.
    func swatch(_ preset: Preset) -> RGB {
        switch preset.source {
        case .color, .effect: preset.color ?? .white
        case .white: ColorMath.kelvin(preset.kelvin ?? 4000)
        case .mirror: RGB(90, 90, 110)
        }
    }

    // MARK: - Mirror

    func startMirror() {
        guard let endpoint, let info else { return }
        colorSource = .mirror
        mirrorMessage = nil
        if state?.on == false { submit(StatePatch(on: true)) }
        if !MirrorEngine.hasPermission { MirrorEngine.requestPermission() }
        let ddpPort = browser.devices.first { $0.id == info.id }?.txt["ddp"].flatMap(Int.init) ?? info.ddp.port
        let settings = deviceSettings.mirror
        Task {
            do {
                try await mirror.start(settings: settings, ledCount: info.ledCount, device: endpoint, ddpPort: ddpPort)
                mirroring = true
                watchMirror()
            } catch {
                mirroring = false
                mirrorMessage = error.localizedDescription
            }
        }
    }

    func stopMirror() {
        mirrorPoll?.cancel()
        mirrorPoll = nil
        mirror.stop()
        mirroring = false
        mirrorPreview = []
    }

    func mirrorSettingsChanged(_ settings: MirrorSettings) {
        let previous = deviceSettings.mirror
        deviceSettings.mirror = settings
        guard mirroring else { return }
        if settings.displayUUID == previous.displayUUID && settings.fps == previous.fps, let info {
            Task { await mirror.update(settings: settings, ledCount: info.ledCount) }
        } else {
            startMirror()
        }
    }

    var needsScreenPermission: Bool { mirrorMessage == MirrorError.permissionDenied.errorDescription }

    func openScreenRecordingSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    private func mirrorStopped(_ message: String) {
        stopMirror()
        mirrorMessage = message
        if let state { adopt(state) }
    }

    /// Two polls in a row without our stream, while the strip is on, mean another client
    /// took over (for example a PATCH with mode).
    private func watchMirror() {
        mirrorPoll?.cancel()
        mirrorPoll = Task {
            var misses = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, let s = try? await call({ try await $0.state() }) else { continue }
                let ours = s.realtime.active && s.realtime.source.map(LocalAddresses.contains) == true
                misses = ours || !s.on ? 0 : misses + 1
                if misses >= 2 {
                    mirrorStopped("Mirroring stopped by another device")
                    state = s
                    adopt(s)
                    return
                }
            }
        }
    }

    // MARK: - Sleep and lock

    /// The display the strip is mounted on is the one Follow monitor or Mirror uses. Switched
    /// off or unplugged, it leaves the online list, and the strip turns off as for display sleep.
    private func checkStripDisplay() {
        guard let uuid = deviceSettings.follow.displayUUID ?? deviceSettings.mirror.displayUUID else { return }
        let online = Displays.display(uuid: uuid) != nil
        guard online != stripDisplayOnline else { return }
        stripDisplayOnline = online
        handle(online ? .displayOn : .displayOff)
    }

    private func handle(_ event: PowerEvent) {
        sleep.offOnSleep = settings.offOnSleep
        sleep.offOnLock = settings.offOnLock
        switch sleep.handle(event) {
        case .turnOff: Task { await turnOffForSleep() }
        case .restore: Task { await restoreAfterSleep() }
        case nil: break
        }
    }

    private func turnOffForSleep() async {
        let wasOn = state?.on ?? false
        let wasMirroring = mirroring
        follower.paused = true
        if mirroring { stopMirror() }
        guard wasOn else {
            sleepRecord = (false, wasMirroring, state?.rev)
            return
        }
        let s = try? await call { try await $0.patch(StatePatch(on: false, transitionMs: 1000)) }
        if let s { state = s }
        sleepRecord = (true, wasMirroring, s?.rev)
    }

    /// Turns the strip back on only if nobody changed it meanwhile (same `rev`).
    private func restoreAfterSleep() async {
        guard let record = sleepRecord else { return }
        sleepRecord = nil
        var current: LightState?
        for _ in 0..<10 {  // WiFi reconnects after wake
            if let api, let s = try? await api.state() {
                current = s
                break
            }
            try? await Task.sleep(for: .seconds(1))
        }
        guard let current else {
            connect()
            return
        }
        adopt(current)
        guard record.wasOn, current.rev == record.rev else { return }
        if let s = try? await call({ try await $0.patch(StatePatch(on: true)) }) { adopt(s) }
        if record.wasMirroring { startMirror() }
    }

    // MARK: - Device settings

    func loadConfig() async {
        config = try? await call { try await $0.config() }
        if let info = try? await call({ try await $0.info() }) { self.info = info }
    }

    func applyConfig(_ patch: ConfigPatch) async -> String? {
        do {
            config = try await call { try await $0.patchConfig(patch) }
            if let info = try? await call({ try await $0.info() }) { self.info = info }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func identify() {
        Task { try? await call { try await $0.identify() } }
    }

    func forgetWifi() {
        Task {
            try? await call { try await $0.forgetWifi() }
            stopMirror()
            follower.stop()
            connection = .failed("The device restarted into setup. Join its \"Pixelvisor-…\" WiFi network to set it up again.")
            api = nil
        }
    }

    func reboot() {
        Task {
            try? await call { try await $0.reboot() }
            try? await Task.sleep(for: .seconds(3))
            await waitForDevice(previousUptime: nil)
        }
    }

    func uploadFirmware(_ url: URL) {
        guard let api, let info else { return }
        upload = .uploading(0)
        Task {
            do {
                let image = try Data(contentsOf: url)
                try await api.uploadFirmware(image) { progress in
                    Task { @MainActor in AppModel.shared.upload = .uploading(progress) }
                }
                upload = .restarting
                try? await Task.sleep(for: .seconds(3))
                if let fw = await waitForDevice(previousUptime: info.uptimeS) {
                    upload = .done(fw)
                } else {
                    upload = .failed("The device did not come back within 30 s")
                }
            } catch {
                upload = .failed(error.localizedDescription)
            }
        }
    }

    /// Polls until the device answers after a restart (uptime went down), up to 30 s.
    @discardableResult
    private func waitForDevice(previousUptime: Int?) async -> String? {
        for _ in 0..<30 {
            if let endpoint = await locate() ?? endpoint, let info = try? await PixelvisorAPI(endpoint: endpoint).info(),
               previousUptime.map({ info.uptimeS < $0 }) ?? true {
                self.info = info
                connect()
                return info.fw
            }
            try? await Task.sleep(for: .seconds(1))
        }
        return nil
    }

    func clearUpload() {
        upload = nil
    }
}

/// IPv4 addresses of this Mac, to recognise our own DDP stream in `realtime.source`.
enum LocalAddresses {
    static func contains(_ address: String) -> Bool { ipv4().contains(address) }

    static func ipv4() -> Set<String> {
        var result: Set<String> = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return result }
        defer { freeifaddrs(list) }
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let addr = entry.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                result.insert(String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
            }
        }
        return result
    }
}
