// The dropdown panel. Changes apply live; there is no apply button.

import SwiftUI

struct PanelView: View {
    let model: AppModel
    @Environment(\.openSettings) private var openSettings
    @State private var renaming: Preset?
    @State private var newName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if model.connection == .connected, let state = model.state {
                Divider()
                brightness(state)
                Divider()
                Picker("Color source", selection: Binding(get: { model.colorSource }, set: { model.select($0) })) {
                    ForEach(ColorSource.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                sourceControls(state)
                if let notice = model.notice {
                    Text(notice).font(.caption).foregroundStyle(.red)
                }
                Divider()
                presets
            } else {
                disconnected
            }
            Divider()
            HStack {
                Button("Settings…") { showSettings() }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless)
        }
        .padding(14)
        .frame(width: 300)
        .onAppear { model.panelOpened() }
        .onDisappear { model.panelClosed() }
        .alert("Rename preset", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") { if let renaming { model.renamePreset(renaming.id, to: newName) } }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func showSettings() {
        NSApp.activate()
        openSettings()
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 8) {
            Text(model.deviceName).font(.headline)
            Circle().fill(model.connection == .connected ? Color.green : Color.secondary).frame(width: 7, height: 7)
            Text(statusText).font(.caption).foregroundStyle(.secondary)
            Spacer()
            if let state = model.state, model.connection == .connected {
                Toggle("Power", isOn: Binding(get: { state.on }, set: { _ in model.togglePower() }))
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
        }
    }

    private var statusText: String {
        switch model.connection {
        case .connected: model.mirroring ? "mirroring" : "connected"
        case .connecting: "connecting"
        case .searching: "searching"
        case .failed: "offline"
        }
    }

    private func brightness(_ state: LightState) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "sun.max")
                Slider(value: Binding(get: { model.brightnessLevel }, set: { model.setBrightnessLevel($0) }), in: 0...1)
                Text("\(Int((model.brightnessLevel * 100).rounded())) %").monospacedDigit().frame(width: 40, alignment: .trailing)
            }
            if model.follower.isSupported {
                Picker("Brightness source", selection: Binding(get: { model.settings.brightnessSource }, set: { model.setBrightnessSource($0) })) {
                    Text("Manual").tag(BrightnessSource.manual)
                    Text("Follow monitor").tag(BrightnessSource.followMonitor)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                if model.settings.brightnessSource == .followMonitor {
                    Text(followText).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var followText: String {
        switch model.follower.state {
        case let .following(monitor, output): "Following monitor: \(monitor) % → strip \(Int((Double(output) / 2.55).rounded())) %"
        case let .unavailable(reason): reason.rawValue
        case .paused: "Paused while the strip is off"
        case .idle: "Starting…"
        }
    }

    @ViewBuilder
    private func sourceControls(_ state: LightState) -> some View {
        switch model.colorSource {
        case .color:
            ColorBars(hue: model.hue, saturation: model.saturation) { model.setColor(hue: $0, saturation: $1) }
        case .white:
            VStack(alignment: .leading, spacing: 4) {
                GradientSlider(colors: [2000, 3000, 4000, 5000, 6500].map { Color(ColorMath.kelvin($0)) },
                               value: Double(model.settings.whiteKelvin - 2000) / 4500) {
                    model.setKelvin(2000 + Int(($0 * 4500 / 100).rounded()) * 100)
                }
                Text("\(model.settings.whiteKelvin) K").font(.caption).foregroundStyle(.secondary)
            }
        case .effect:
            effectControls(state)
        case .mirror:
            mirrorControls
        }
    }

    @ViewBuilder
    private func effectControls(_ state: LightState) -> some View {
        Picker("Effect", selection: Binding(get: { state.effect.id }, set: { model.setEffect(EffectPatch(id: $0)) })) {
            ForEach(model.effects) { Text($0.name).tag($0.id) }
        }
        let effect = model.currentEffect
        if effect?.uses("color") == true {
            let hs = ColorMath.hueSaturation(state.color)
            labeled("Color") { ColorBars(hue: hs.hue, saturation: hs.saturation) { model.setEffectColor(ColorMath.color(hue: $0, saturation: $1)) } }
        }
        if effect?.uses("color2") == true {
            let hs = ColorMath.hueSaturation(state.effect.color2)
            labeled("Color 2") {
                ColorBars(hue: hs.hue, saturation: hs.saturation) {
                    model.setEffect(EffectPatch(color2: ColorMath.color(hue: $0, saturation: $1)), transitionMs: 150)
                }
            }
        }
        if effect?.uses("speed") == true {
            labeled("Speed") {
                Slider(value: Binding(get: { Double(state.effect.speed) }, set: { model.setEffect(EffectPatch(speed: Int($0))) }), in: 0...255)
            }
        }
    }

    @ViewBuilder
    private var mirrorControls: some View {
        let mirror = model.deviceSettings.mirror
        Picker("Display", selection: Binding(get: { mirror.displayUUID ?? Displays.uuid(CGMainDisplayID()) ?? "" }, set: {
            var m = mirror
            m.displayUUID = $0
            model.mirrorSettingsChanged(m)
        })) {
            ForEach(Displays.online(), id: \.self) { id in Text(Displays.name(id)).tag(Displays.uuid(id) ?? "") }
        }
        Picker("Style", selection: Binding(get: { mirror.style }, set: {
            var m = mirror
            m.style = $0
            model.mirrorSettingsChanged(m)
        })) {
            Text("Zones").tag(MirrorStyle.zones)
            Text("Average").tag(MirrorStyle.average)
        }
        .pickerStyle(.segmented)
        if model.mirroring {
            PreviewStrip(colors: model.mirrorPreview)
        } else if let message = model.mirrorMessage {
            Text(message).font(.caption).foregroundStyle(.secondary)
            HStack {
                if model.needsScreenPermission {
                    Button("Open Screen Recording Settings") { model.openScreenRecordingSettings() }
                }
                Button("Retry") { model.startMirror() }
            }
        } else {
            Text("Starting…").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var presets: some View {
        HStack(spacing: 8) {
            ForEach(model.settings.presets) { preset in
                Button { model.apply(preset) } label: {
                    Circle().fill(Color(model.swatch(preset))).frame(width: 18, height: 18)
                        .overlay(Circle().strokeBorder(.secondary.opacity(0.4)))
                }
                .buttonStyle(.plain)
                .help(preset.name)
                .contextMenu {
                    Button("Rename…") {
                        newName = preset.name
                        renaming = preset
                    }
                    Button("Update") { model.updatePreset(preset.id) }
                    Button("Delete", role: .destructive) { model.deletePreset(preset.id) }
                }
            }
            Spacer()
            if model.settings.presets.count < AppSettings.maxPresets {
                Button("+ Save preset") { model.savePreset() }.buttonStyle(.borderless)
            }
        }
    }

    private var disconnected: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch model.connection {
            case let .failed(message): Text(message).foregroundStyle(.secondary)
            default: Text("Looking for Pixelvisor…").foregroundStyle(.secondary)
            }
            HStack {
                Button("Retry") { model.connect() }
                Button("Settings…") { showSettings() }
            }
        }
    }

    private func labeled(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        HStack {
            Text(title).font(.caption).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
            content()
        }
    }
}

// MARK: - Controls

extension Color {
    init(_ c: RGB) {
        self.init(red: Double(c.r) / 255, green: Double(c.g) / 255, blue: Double(c.b) / 255)
    }
}

/// A capsule with a gradient and a draggable knob; `value` is 0...1.
struct GradientSlider: View {
    let colors: [Color]
    let value: Double
    let onChange: (Double) -> Void

    var body: some View {
        GeometryReader { geo in
            let knob = 14.0, travel = max(geo.size.width - knob, 1)
            ZStack(alignment: .leading) {
                Capsule().fill(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing))
                Circle().strokeBorder(.white, lineWidth: 2).shadow(radius: 1).frame(width: knob, height: knob)
                    .offset(x: min(max(value, 0), 1) * travel)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { onChange(min(max(($0.location.x - knob / 2) / travel, 0), 1)) })
        }
        .frame(height: 14)
    }
}

/// Hue and saturation bars, inline. A ColorPicker would open a separate window and close
/// the panel.
struct ColorBars: View {
    let hue: Double
    let saturation: Double
    let onChange: (Double, Double) -> Void

    var body: some View {
        VStack(spacing: 8) {
            GradientSlider(colors: stride(from: 0.0, through: 1.0, by: 1 / 6).map { Color(hue: $0, saturation: 1, brightness: 1) },
                           value: hue) { onChange($0, saturation) }
            GradientSlider(colors: [.white, Color(hue: hue, saturation: 1, brightness: 1)], value: saturation) { onChange(hue, $0) }
        }
    }
}

struct PreviewStrip: View {
    let colors: [RGB]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(colors.enumerated()), id: \.offset) { Rectangle().fill(Color($0.element)) }
        }
        .frame(height: 10)
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }
}
