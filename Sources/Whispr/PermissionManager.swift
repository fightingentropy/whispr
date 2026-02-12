import AppKit
import AVFoundation
import ApplicationServices
import Foundation

final class PermissionManager {
    func microphonePermissionGranted() -> Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    func requestMicrophonePermission(completion: @escaping (Bool) -> Void) {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            completion(true)
        case .denied, .restricted:
            completion(false)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio, completionHandler: completion)
        @unknown default:
            completion(false)
        }
    }

    func accessibilityPermissionGranted() -> Bool {
        AXIsProcessTrusted()
    }

    func requestAccessibilityPrompt() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}
