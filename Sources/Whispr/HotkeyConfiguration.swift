import Carbon.HIToolbox
import Foundation

enum HotkeyPreset: String, CaseIterable, Codable {
    case rightCommand
    case optionSpace
    case commandSpace
    case controlSpace

    var displayName: String {
        switch self {
        case .rightCommand: return "Right Command (hold)"
        case .optionSpace: return "Option + Space"
        case .commandSpace: return "Command + Space"
        case .controlSpace: return "Control + Space"
        }
    }

    /// Carbon modifier flags for RegisterEventHotKey (used when Carbon can handle it)
    var carbonModifiers: UInt32 {
        switch self {
        case .rightCommand: return 0 // Carbon can't distinguish; use event monitor
        case .optionSpace: return UInt32(optionKey)
        case .commandSpace: return UInt32(cmdKey)
        case .controlSpace: return UInt32(controlKey)
        }
    }

    /// Whether we need NSEvent monitor (for right command) vs Carbon
    var requiresEventMonitor: Bool {
        self == .rightCommand
    }

    /// Key code for the trigger key
    var keyCode: UInt32 {
        UInt32(kVK_Space)
    }
}
