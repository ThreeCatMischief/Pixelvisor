// Entry point: a menu bar extra with a window-style panel, plus the Settings window.

import AppKit
import SwiftUI

@main
struct PixelvisorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private let hub = Hub.shared

    var body: some Scene {
        MenuBarExtra {
            PanelView(hub: hub)
        } label: {
            Image(nsImage: StatusIcon.image(hub.iconState))
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(hub: hub)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)  // also without the bundle's LSUIElement, e.g. `swift run`
        Hub.shared.start()
    }
}
