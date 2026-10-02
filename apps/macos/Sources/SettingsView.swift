// Settings window: rarely used options.

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    let model: AppModel

    var body: some View {
        TabView {
            GeneralTab(model: model).tabItem { Label("General", systemImage: "gearshape") }
            DeviceTab(model: model).tabItem { Label("Device", systemImage: "light.strip.2") }
            BrightnessTab(model: model).tabItem { Label("Brightness", systemImage: "sun.max") }
            MirrorTab(model: model).tabItem { Label("Mirror", systemImage: "display") }
            AboutTab().tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 560, height: 640)
        .padding(20)
    }
}

private struct GeneralTab: View {
    let model: AppModel
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var error: String?

    var body: some View {
        Form {
            Toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, on in
                    do { try LoginItem.set(on) } catch { self.error = error.localizedDescription }
                    launchAtLogin = LoginItem.isEnabled
                }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            Toggle("Turn off when the display sleeps or is switched off", isOn: Binding(get: { model.settings.offOnSleep }, set: { model.settings.offOnSleep = $0 }))
            Toggle("Turn off on lock", isOn: Binding(get: { model.settings.offOnLock }, set: { model.settings.offOnLock = $0 }))
        }
    }
}

private struct DeviceTab: View {
    let model: AppModel
    @State private var manual = ""
    @State private var draft: DeviceConfig?
    @State private var message: String?
    @State private var confirmReboot = false
    @State private var confirmForget = false

    var body: some View {
        Form {
            Section("Device") {
                ForEach(model.browser.devices) { device in
                    HStack {
                        Text(device.name)
                        Text(device.txt["fw"].map { "fw \($0)" } ?? "").foregroundStyle(.secondary)
                        Spacer()
                        if model.settings.manualEndpoint == nil && model.info?.id == device.id {
                            Image(systemName: "checkmark")
                        } else {
                            Button("Use") { model.useDevice(id: device.id) }
                        }
                    }
                }
                HStack {
                    TextField("Manual address", text: $manual, prompt: Text("192.168.1.42:80"))
                    Button("Use") { message = model.useManualEndpoint(manual) ? nil : "Enter host or host:port" }
                    if model.settings.manualEndpoint != nil {
                        Button("Clear") {
                            model.settings.manualEndpoint = nil
                            model.connect()
                        }
                    }
                }
                if let info = model.info {
                    LabeledContent("Firmware", value: "\(info.fw) (API \(info.api), \(info.board))")
                    LabeledContent("Address", value: "\(model.endpoint?.description ?? info.ip), \(info.hostname).local")
                    LabeledContent("Signal", value: "\(info.rssi) dBm")
                    LabeledContent("Uptime", value: Duration.seconds(info.uptimeS).formatted(.units(allowed: [.days, .hours, .minutes], width: .abbreviated)))
                    Button("Identify") { model.identify() }
                }
            }

            if draft != nil {
                Section("Configuration") {
                    TextField("Name", text: binding(\.name))
                    TextField("LED count", value: binding(\.ledCount), format: .number.grouping(.never))
                    Picker("Color order", selection: binding(\.colorOrder)) {
                        ForEach(DeviceConfig.colorOrders, id: \.self) { Text($0) }
                    }
                    Toggle("First LED is at the right end", isOn: binding(\.reverse))
                    TextField("Current limit (mA, 0 = off)", value: binding(\.maxCurrentMa), format: .number.grouping(.never))
                    LabeledContent("White balance") {
                        HStack {
                            TextField("R", value: binding(\.whiteBalance.r), format: .number)
                            TextField("G", value: binding(\.whiteBalance.g), format: .number)
                            TextField("B", value: binding(\.whiteBalance.b), format: .number)
                        }
                    }
                    Picker("After power loss", selection: binding(\.powerOn)) {
                        Text("Restore").tag("restore")
                        Text("On").tag("on")
                        Text("Off").tag("off")
                    }
                    HStack {
                        Button("Save") {
                            NSApp.keyWindow?.makeFirstResponder(nil)  // number fields update their binding only when editing ends
                            Task { await save() }
                        }
                        .keyboardShortcut("s")
                        if model.config?.rebootRequired == true {
                            Button("Reboot to apply") { model.reboot() }
                        }
                        if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }

            Section("Maintenance") {
                HStack {
                    Button("Reboot") { confirmReboot = true }
                    Button("Update firmware…") { chooseFirmware() }
                    Button("Forget WiFi…") { confirmForget = true }
                }
                switch model.upload {
                case let .uploading(p): ProgressView(value: p) { Text("Uploading") }
                case .restarting: ProgressView { Text("Waiting for the device to restart") }
                case let .done(fw): Text("Updated to \(fw)").foregroundStyle(.secondary)
                case let .failed(error): Text(error).foregroundStyle(.red)
                case nil: EmptyView()
                }
            }
        }
        .formStyle(.grouped)
        .task(id: model.info?.id) {
            await model.loadConfig()
            draft = model.config
            manual = model.settings.manualEndpoint ?? ""
        }
        .confirmationDialog("Reboot the device?", isPresented: $confirmReboot) {
            Button("Reboot") { model.reboot() }
        }
        .confirmationDialog("Forget the WiFi network?", isPresented: $confirmForget) {
            Button("Forget WiFi", role: .destructive) { model.forgetWifi() }
        } message: {
            Text("The device restarts and opens its setup network until you choose a WiFi network again.")
        }
    }

    private func binding<T>(_ path: WritableKeyPath<DeviceConfig, T>) -> Binding<T> {
        Binding(get: { draft![keyPath: path] }, set: { draft![keyPath: path] = $0 })
    }

    /// Sends the fields that differ from the device's config, then reads the config back
    /// and reports whether the device holds the edited values.
    private func save() async {
        guard let draft, let config = model.config else { return }
        let patch = ConfigPatch(from: config, to: draft)
        guard patch != ConfigPatch() else {
            message = "No changes"
            return
        }
        message = "Saving…"
        if let error = await model.applyConfig(patch) {
            message = error
            return
        }
        await model.loadConfig()
        guard let stored = model.config else {
            message = "Sent, but the device did not answer the read-back"
            return
        }
        message = ConfigPatch(from: stored, to: draft) == ConfigPatch() ? "Saved" : "Device stored different values"
        self.draft = stored
    }

    private func chooseFirmware() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "bin") ?? .data]
        panel.message = "Choose firmware.bin from a Pixelvisor release"
        NSApp.activate()
        if panel.runModal() == .OK, let url = panel.url { model.uploadFirmware(url) }
    }
}

private struct BrightnessTab: View {
    let model: AppModel

    var body: some View {
        let follow = model.deviceSettings.follow
        Form {
            if !model.follower.isSupported {
                Text("Follow monitor reads the monitor's brightness over DDC, which needs Apple Silicon.")
            }
            Picker("Display", selection: Binding(get: { follow.displayUUID ?? "" }, set: { set(\.displayUUID, $0.isEmpty ? nil : $0) })) {
                Text("First external display").tag("")
                ForEach(Displays.external(), id: \.self) { id in Text(Displays.name(id)).tag(Displays.uuid(id) ?? "") }
            }
            slider("Floor", value: follow.curve.floor, range: 0...0.5) { set(\.curve.floor, $0) }
            slider("Ceiling", value: follow.curve.ceiling, range: 0.5...1) { set(\.curve.ceiling, $0) }
            slider("Gamma", value: follow.curve.gamma, range: 0.5...3) { set(\.curve.gamma, $0) }
            slider("Poll every (s)", value: follow.pollSeconds, range: 1...10, step: 1) { set(\.pollSeconds, $0) }
            LabeledContent("Now") {
                switch model.follower.state {
                case let .following(monitor, output): Text("monitor \(monitor) % → strip \(output) / 255")
                case let .unavailable(reason): Text(reason.rawValue)
                case .paused: Text("paused")
                case .idle: Text("not following (choose Follow monitor in the panel)")
                }
            }
            CurvePreview(curve: follow.curve).frame(height: 120)
        }
        .formStyle(.grouped)
    }

    private func set<T>(_ path: WritableKeyPath<FollowSettings, T>, _ value: T) {
        var follow = model.deviceSettings.follow
        follow[keyPath: path] = value
        model.followSettingsChanged(follow)
    }
}

private struct CurvePreview: View {
    let curve: BrightnessCurve

    var body: some View {
        Canvas { context, size in
            var path = Path()
            for i in 0...50 {
                let m = Double(i) / 50
                let y = Double(curve.output(current: i, max: 50, level: 1)) / 255
                let point = CGPoint(x: m * size.width, y: (1 - y) * size.height)
                if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            context.stroke(path, with: .color(.accentColor), lineWidth: 2)
            context.stroke(Path(CGRect(origin: .zero, size: size)), with: .color(.secondary.opacity(0.3)))
        }
        .help("Monitor brightness (x) to strip brightness (y)")
    }
}

private struct MirrorTab: View {
    let model: AppModel

    var body: some View {
        let mirror = model.deviceSettings.mirror
        let leds = model.info?.ledCount ?? 43
        Form {
            Picker("Display", selection: Binding(get: { mirror.displayUUID ?? "" }, set: { set(\.displayUUID, $0.isEmpty ? nil : $0) })) {
                Text("Main display").tag("")
                ForEach(Displays.online(), id: \.self) { id in Text(Displays.name(id)).tag(Displays.uuid(id) ?? "") }
            }
            Picker("Style", selection: Binding(get: { mirror.style }, set: { set(\.style, $0) })) {
                Text("Zones").tag(MirrorStyle.zones)
                Text("Average").tag(MirrorStyle.average)
            }
            slider("Band height (from the top)", value: mirror.bandHeight, range: 0.05...1) { set(\.bandHeight, $0) }
            Stepper("First LED under the screen: \(mirror.ledStart)", value: Binding(get: { mirror.ledStart }, set: { set(\.ledStart, $0) }), in: 0...(leds - 1))
            Stepper("Last LED under the screen: \(mirror.ledEnd ?? leds - 1)",
                    value: Binding(get: { mirror.ledEnd ?? leds - 1 }, set: { set(\.ledEnd, $0 == leds - 1 ? nil : $0) }), in: mirror.ledStart...(leds - 1))
            Picker("LEDs outside that range", selection: Binding(get: { mirror.outside }, set: { set(\.outside, $0) })) {
                Text("Nearest edge color").tag(OutsideRange.extend)
                Text("Off").tag(OutsideRange.off)
            }
            slider("Saturation", value: mirror.saturation, range: 1...2) { set(\.saturation, $0) }
            slider("Smoothing (ms)", value: mirror.smoothingMs, range: 0...500, step: 10) { set(\.smoothingMs, $0) }
            Picker("Frame rate", selection: Binding(get: { mirror.fps }, set: { set(\.fps, $0) })) {
                ForEach([15, 30, 60], id: \.self) { Text("\($0) fps").tag($0) }
            }
            if model.mirroring {
                PreviewStrip(model: model, height: 16)
            } else {
                Text("Choose Mirror in the panel to see a live preview.").foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func set<T>(_ path: WritableKeyPath<MirrorSettings, T>, _ value: T) {
        var mirror = model.deviceSettings.mirror
        mirror[keyPath: path] = value
        model.mirrorSettingsChanged(mirror)
    }
}

private struct AboutTab: View {
    var body: some View {
        Form {
            LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")
            LabeledContent("Protocol API", value: "\(PixelvisorAPI.supportedAPI)")
            Text("DDC access adapted from MonitorControl (github.com/MonitorControl/MonitorControl), MIT License, © MonitorControl contributors.")
                .font(.caption)
            Text("Pixelvisor is MIT licensed.").font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}

/// A labeled slider with the current value.
@MainActor
private func slider(_ title: String, value: Double, range: ClosedRange<Double>, step: Double? = nil,
                    set: @escaping @MainActor (Double) -> Void) -> some View {
    let binding = Binding(get: { value }, set: { v in MainActor.assumeIsolated { set(v) } })
    return LabeledContent(title) {
        HStack {
            if let step {
                Slider(value: binding, in: range, step: step)
            } else {
                Slider(value: binding, in: range)
            }
            Text(value.formatted(.number.precision(.fractionLength(step == nil ? 2 : 0)))).monospacedDigit().frame(width: 40)
        }
    }
}
