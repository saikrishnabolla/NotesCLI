import AppKit
import Carbon
import CoreGraphics

struct EditorKeyTapRecovery {
    enum Listener { case missing, enabled, disabled }
    enum Action: Equatable { case none, stop, install, resume }

    private var target: pid_t?
    private var interceptsNavigation = false
    private var nextAttempt: TimeInterval = 0

    mutating func action(for pid: pid_t?, interceptNavigation: Bool, listener: Listener,
                         now: TimeInterval) -> Action {
        guard let pid else {
            let shouldStop = target != nil
            self = Self()
            return shouldStop ? .stop : .none
        }
        if target != pid || interceptsNavigation != interceptNavigation {
            target = pid
            interceptsNavigation = interceptNavigation
            nextAttempt = now + 1
            return .install
        }
        guard listener != .enabled, now >= nextAttempt else { return .none }
        nextAttempt = now + 1
        return listener == .disabled ? .resume : .install
    }
}

@MainActor
final class EditorKeyTap {
    enum Key {
        case up, down, accept, dismiss, space, slash, other
    }

    struct Input {
        let key: Key
        let letterOrDigit: String?
        let returnCode: CGKeyCode?
    }

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var attemptedPID: pid_t?
    private var interceptNavigation = false
    private var recovery = EditorKeyTapRecovery()
    var receive: ((Input) -> Bool)?
    var lost: (() -> Void)?
    private static let forwardedReturnTag: Int64 = 0x4e434c494e4c

    static func isDirectKeyboardLayout() -> Bool {
        guard let input = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(input, kTISPropertyInputSourceType) else { return false }
        let type = Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue()
        return CFEqual(type, kTISTypeKeyboardLayout)
    }

    func watch(_ pid: pid_t?, interceptNavigation: Bool) {
        let listener: EditorKeyTapRecovery.Listener = tap.map {
            guard CFMachPortIsValid($0) else { return .missing }
            return CGEvent.tapIsEnabled(tap: $0) ? .enabled : .disabled
        } ?? .missing
        switch recovery.action(for: pid, interceptNavigation: interceptNavigation, listener: listener,
                               now: ProcessInfo.processInfo.systemUptime) {
        case .none:
            return
        case .stop:
            removeListener()
            return
        case .resume:
            lost?()
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
                if !CGEvent.tapIsEnabled(tap: tap) { removeListener() }
            }
            return
        case .install:
            if tap != nil { lost?() }
            removeListener()
        }
        guard let pid else { return }
        attemptedPID = pid
        self.interceptNavigation = interceptNavigation
        let mask = CGEventMask(1) << CGEventType.keyDown.rawValue
        let options: CGEventTapOptions = interceptNavigation ? .defaultTap : .listenOnly
        guard let tap = CGEvent.tapCreateForPid(pid: pid, place: .headInsertEventTap, options: options,
                                               eventsOfInterest: mask, callback: { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let owner = Unmanaged<EditorKeyTap>.fromOpaque(context).takeUnretainedValue()
            if type != .keyDown {
                _ = MainActor.assumeIsolated { owner.process(type, flags: [], code: 0, unit: nil) }
                return Unmanaged.passUnretained(event)
            }
            let flags = event.flags.rawValue
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            var unit: UniChar = 0
            var count = 0
            event.keyboardGetUnicodeString(maxStringLength: 1, actualStringLength: &count, unicodeString: &unit)
            let suppress = MainActor.assumeIsolated {
                guard event.getIntegerValueField(.eventSourceUserData) != EditorKeyTap.forwardedReturnTag else { return false }
                return owner.process(type, flags: CGEventFlags(rawValue: flags), code: code, unit: count == 1 ? unit : nil)
            }
            return suppress ? nil : Unmanaged.passUnretained(event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            return
        }
        self.tap = tap
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        removeListener()
        recovery = EditorKeyTapRecovery()
    }

    private func removeListener() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        source = nil
        tap = nil
        attemptedPID = nil
        interceptNavigation = false
    }

    private func process(_ type: CGEventType, flags: CGEventFlags, code: Int64, unit: UniChar?) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            lost?()
            return false
        }
        guard type == .keyDown, attemptedPID == NotesEditorAccess.frontmostPID() else {
            return false
        }
        let unit = unit ?? Self.layoutUnit(for: code, flags: flags)
        let key = Self.key(flags: flags, code: code, typedSlash: unit == 47)
        if !interceptNavigation && key != .space && key != .slash && key != .other { return false }
        let printable = flags.intersection([.maskCommand, .maskControl, .maskAlternate]).isEmpty
            ? unit.flatMap(Unicode.Scalar.init) : nil
        let letterOrDigit = printable.flatMap { scalar -> String? in
            let value = scalar.value
            guard (48...57).contains(value) || (65...90).contains(value) || (97...122).contains(value) else { return nil }
            return String(scalar)
        }
        return receive?(Input(key: key, letterOrDigit: letterOrDigit,
                              returnCode: key == .accept ? CGKeyCode(exactly: code) : nil)) == true
    }

    private static func layoutUnit(for code: Int64, flags: CGEventFlags) -> UniChar? {
        guard flags.intersection([.maskCommand, .maskControl]).isEmpty, let keyCode = UInt16(exactly: code),
              let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = unsafeBitCast(raw, to: CFData.self)
        guard let bytes = CFDataGetBytePtr(data) else { return nil }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        var modifiers: Int = 0
        if flags.contains(.maskShift) { modifiers |= shiftKey }
        if flags.contains(.maskAlternate) { modifiers |= optionKey }
        if flags.contains(.maskAlphaShift) { modifiers |= alphaLock }
        var state: UInt32 = 0
        var count = 0
        var output = [UniChar](repeating: 0, count: 4)
        let status = UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDown), UInt32(modifiers >> 8),
                                    UInt32(LMGetKbdType()), 0, &state, output.count, &count, &output)
        guard status == noErr, state == 0, count == 1 else { return nil }
        return output[0]
    }

    static func forwardReturn(_ code: CGKeyCode, to pid: pid_t) {
        // Only unmodified Return/Enter is deferred. Tag the fallback so our tap
        // never treats it as another shortcut.
        guard code == 36 || code == 76,
              let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false) else { return }
        for event in [down, up] {
            event.flags = []
            event.setIntegerValueField(.eventSourceUserData, value: forwardedReturnTag)
            event.postToPid(pid)
        }
    }

    static func key(flags: CGEventFlags, code: Int64, typedSlash: Bool) -> Key {
        if typedSlash, flags.intersection([.maskCommand, .maskControl]).isEmpty { return .slash }
        guard flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]).isEmpty else {
            return .other
        }
        switch code {
        case 126: return .up
        case 125: return .down
        case 36, 76: return .accept
        case 53: return .dismiss
        case 49: return .space
        default: return .other
        }
    }
}
