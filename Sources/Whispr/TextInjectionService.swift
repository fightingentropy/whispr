import AppKit
import ApplicationServices
import Foundation

final class ActiveAppTextInjectionService: TextInjectionService {
    private let pasteKeyCode: CGKeyCode = 9 // ANSI V

    func insert(text: String) throws {
        guard !text.isEmpty else { return }

        let previousClipboard = NSPasteboard.general.string(forType: .string)
        guard NSPasteboard.general.clearContents() != 0 else {
            throw DictationError.textInjection("Failed to clear clipboard.")
        }
        guard NSPasteboard.general.setString(text, forType: .string) else {
            throw DictationError.textInjection("Failed to write transcript to clipboard.")
        }

        guard AXIsProcessTrusted() else {
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            let options = [key: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            if let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(settingsURL)
            }
            throw DictationError.textInjection(
                "Transcript copied to clipboard. Enable Whispr in System Settings -> Privacy & Security -> Accessibility for auto-paste."
            )
        }

        try postCommandV()
        restoreClipboard(previousClipboard)
    }

    private func postCommandV() throws {
        guard let eventSource = CGEventSource(stateID: .hidSystemState) else {
            throw DictationError.textInjection("Failed to create keyboard event source.")
        }

        guard let keyDown = CGEvent(
            keyboardEventSource: eventSource,
            virtualKey: pasteKeyCode,
            keyDown: true
        ) else {
            throw DictationError.textInjection("Failed to build key-down paste event.")
        }
        keyDown.flags = .maskCommand

        guard let keyUp = CGEvent(
            keyboardEventSource: eventSource,
            virtualKey: pasteKeyCode,
            keyDown: false
        ) else {
            throw DictationError.textInjection("Failed to build key-up paste event.")
        }
        keyUp.flags = .maskCommand

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }

    private func restoreClipboard(_ previousValue: String?) {
        guard let previousValue else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            guard NSPasteboard.general.clearContents() != 0 else { return }
            _ = NSPasteboard.general.setString(previousValue, forType: .string)
        }
    }
}
