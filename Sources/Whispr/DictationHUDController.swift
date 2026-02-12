import AppKit
import Combine
import SwiftUI

@MainActor
final class DictationHUDController: ObservableObject {
    private weak var appState: AppState?
    private var statusCancellable: AnyCancellable?
    private var screenObserver: NSObjectProtocol?
    private var hudPanel: NonActivatingHUDPanel?

    deinit {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
    }

    func bind(to appState: AppState) {
        guard self.appState !== appState else { return }
        self.appState = appState

        statusCancellable?.cancel()
        statusCancellable = appState.$status
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] status in
                self?.handle(status: status)
            }

        if screenObserver == nil {
            screenObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.positionHUDIfVisible()
                }
            }
        }

        handle(status: appState.status)
    }

    private func handle(status: DictationStatus) {
        switch status {
        case .listening:
            showHUD()
        case .idle, .transcribing, .error:
            hideHUD()
        }
    }

    private func showHUD() {
        guard let appState else { return }
        let panel = makeHUDPanelIfNeeded(for: appState)
        position(panel)
        panel.orderFrontRegardless()
    }

    private func hideHUD() {
        hudPanel?.orderOut(nil)
    }

    private func positionHUDIfVisible() {
        guard let hudPanel, hudPanel.isVisible else { return }
        position(hudPanel)
    }

    private func makeHUDPanelIfNeeded(for appState: AppState) -> NonActivatingHUDPanel {
        if let hudPanel {
            return hudPanel
        }

        let contentRect = NSRect(x: 0, y: 0, width: 214, height: 62)
        let panel = NonActivatingHUDPanel(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.hasShadow = false
        panel.backgroundColor = .clear
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.isMovable = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: FloatingDictationBarView().environmentObject(appState))

        self.hudPanel = panel
        return panel
    }

    private func position(_ panel: NSPanel) {
        guard let screen = targetScreen else { return }
        let visibleFrame = screen.visibleFrame
        let panelSize = panel.frame.size
        let origin = NSPoint(
            x: visibleFrame.midX - (panelSize.width / 2),
            y: visibleFrame.minY + 26
        )
        panel.setFrameOrigin(origin)
    }

    private var targetScreen: NSScreen? {
        NSApp.keyWindow?.screen ?? NSScreen.main ?? NSScreen.screens.first
    }
}

private final class NonActivatingHUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
