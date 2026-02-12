import Carbon
import Carbon.HIToolbox
import AppKit
import Foundation

protocol HotkeyService {
    var displayName: String { get }
    func start(onPressed: @escaping () -> Void, onReleased: @escaping () -> Void) throws
    func stop()
}

/// Configurable hotkey service supporting presets including Right Command (hold).
final class ConfigurableHotkeyService: HotkeyService {
    private let preset: HotkeyPreset
    private var eventMonitor: Any?
    private var onPressed: (() -> Void)?
    private var onReleased: (() -> Void)?
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private let hotKeyID: EventHotKeyID

    // Track modifier state for Right Command (Carbon can't distinguish left/right)
    private var rightCommandHeld = false

    var displayName: String { preset.displayName }

    init(preset: HotkeyPreset) {
        self.preset = preset
        var id = EventHotKeyID()
        id.signature = OSType(0x57535054) // WSPT
        id.id = UInt32(1)
        hotKeyID = id
    }

    deinit {
        stop()
    }

    func start(onPressed: @escaping () -> Void, onReleased: @escaping () -> Void) throws {
        self.onPressed = onPressed
        self.onReleased = onReleased

        if preset.requiresEventMonitor {
            try startEventMonitor()
        } else {
            try startCarbonHotkey()
        }
    }

    func stop() {
        if let mon = eventMonitor {
            NSEvent.removeMonitor(mon)
            eventMonitor = nil
        }
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
            self.eventHandlerRef = nil
        }
        onPressed = nil
        onReleased = nil
        rightCommandHeld = false
    }

    // MARK: - Right Command (hold) - NSEvent monitor

    private func startEventMonitor() throws {
        rightCommandHeld = false

        let monitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleGlobalEvent(event)
        }

        guard monitor != nil else {
            throw DictationError.hotkey("Unable to register Right Command. Grant Accessibility permission in System Settings → Privacy & Security → Accessibility.")
        }
        eventMonitor = monitor
    }

    private func handleGlobalEvent(_ event: NSEvent) {
        guard event.type == .flagsChanged, event.keyCode == UInt16(kVK_RightCommand) else { return }

        rightCommandHeld.toggle()
        if rightCommandHeld {
            onPressed?()
        } else {
            onReleased?()
        }
    }

    // MARK: - Carbon (Option / Command / Control + Space)

    private func startCarbonHotkey() throws {
        var eventSpecs = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]

        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            Self.eventHandler,
            eventSpecs.count,
            &eventSpecs,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandlerRef
        )
        guard status == noErr else {
            throw DictationError.hotkey("Unable to install hotkey handler (\(status)).")
        }

        let regStatus = RegisterEventHotKey(
            preset.keyCode,
            preset.carbonModifiers,
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &hotKeyRef
        )
        guard regStatus == noErr else {
            RemoveEventHandler(eventHandlerRef!)
            eventHandlerRef = nil
            throw DictationError.hotkey("Unable to register \(preset.displayName) (\(regStatus)).")
        }
    }

    private func handleHotkeyEvent(_ event: EventRef) -> OSStatus {
        var incomingHotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &incomingHotKeyID
        )

        guard status == noErr else { return status }
        guard incomingHotKeyID.id == hotKeyID.id, incomingHotKeyID.signature == hotKeyID.signature else {
            return noErr
        }

        let eventKind = GetEventKind(event)
        if eventKind == UInt32(kEventHotKeyPressed) {
            onPressed?()
        } else if eventKind == UInt32(kEventHotKeyReleased) {
            onReleased?()
        }
        return noErr
    }

    private static let eventHandler: EventHandlerUPP = { _, eventRef, userData in
        guard let eventRef, let userData else { return noErr }
        let service = Unmanaged<ConfigurableHotkeyService>.fromOpaque(userData).takeUnretainedValue()
        return service.handleHotkeyEvent(eventRef)
    }
}
