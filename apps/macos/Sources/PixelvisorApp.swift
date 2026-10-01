// Entry point: a menu bar extra with a window-style panel, plus the Settings window.

import AppKit
import SwiftUI

@main
struct PixelvisorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private let model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            PanelView(model: model)
        } label: {
            Image(nsImage: StatusIcon.image(model.iconState))
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)  // also without the bundle's LSUIElement, e.g. `swift run`
        AppModel.shared.start()
    }
}
