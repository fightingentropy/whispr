import AppKit
import SwiftUI

extension Notification.Name {
    static let openSettingsRequest = Notification.Name("openSettingsRequest")
    static let settingsWindowClosed = Notification.Name("settingsWindowClosed")
}

/// Hidden window providing SwiftUI context for openSettings — required for menu bar apps
/// where Settings would otherwise open in the background or not at all.
struct SettingsOpenerView: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .onReceive(NotificationCenter.default.publisher(for: .openSettingsRequest)) { _ in
                Task { @MainActor in
                    NSApp.setActivationPolicy(.regular)
                    try? await Task.sleep(for: .milliseconds(100))
                    NSApp.activate(ignoringOtherApps: true)
                    openSettings()
                    try? await Task.sleep(for: .milliseconds(200))
                    if let settingsWindow = findSettingsWindow() {
                        settingsWindow.makeKeyAndOrderFront(nil)
                        settingsWindow.orderFrontRegardless()
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .settingsWindowClosed)) { _ in
                NSApp.setActivationPolicy(.accessory)
            }
    }

    private static let settingsWindowIdentifier = "com.apple.SwiftUI.Settings"

    private func findSettingsWindow() -> NSWindow? {
        NSApp.windows.first { window in
            if window.identifier?.rawValue == Self.settingsWindowIdentifier { return true }
            if window.isVisible && window.styleMask.contains(.titled) &&
                (window.title.localizedCaseInsensitiveContains("settings") ||
                 window.title.localizedCaseInsensitiveContains("preferences")) {
                return true
            }
            if let vc = window.contentViewController,
               String(describing: type(of: vc)).contains("Settings") {
                return true
            }
            return false
        }
    }
}

struct HiddenCoordinatorView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var hudController: DictationHUDController

    var body: some View {
        SettingsOpenerView()
            .onAppear {
                hudController.bind(to: appState)
            }
    }
}

@main
struct WhisprApp: App {
    @StateObject private var appState = AppState()
    @StateObject private var dictationHUDController = DictationHUDController()

    var body: some Scene {
        // Hidden window MUST come before Settings for openSettings context to work
        Window("Hidden", id: "HiddenWindow") {
            HiddenCoordinatorView(hudController: dictationHUDController)
                .environmentObject(appState)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 1, height: 1)

        MenuBarExtra {
            MenuBarView()
                .environmentObject(appState)
        } label: {
            Label("Whispr", systemImage: appState.status.systemImage)
        }

        Settings {
            SettingsView()
                .environmentObject(appState)
                .frame(width: 620, height: 460)
                .onDisappear {
                    NotificationCenter.default.post(name: .settingsWindowClosed, object: nil)
                }
        }
    }
}
