import AppKit
import Carbon
import NotesCore

struct EditorHotkey: Hashable {
    let character: Character
    let modifiers: UInt32

    init(_ value: String) throws {
        let pieces = value.lowercased().split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        var mask: UInt32 = 0
        let available: [String: UInt32] = [
            "cmd": UInt32(cmdKey), "shift": UInt32(shiftKey),
            "option": UInt32(optionKey), "ctrl": UInt32(controlKey),
        ]
        let error = NotesError("invalid_editor_hotkey", "Use a modified letter or digit, for example cmd+shift+p.")
        guard let last = pieces.last, last.count == 1, let key = last.first, key.isASCII,
              key.isLetter || key.isNumber else { throw error }
        for word in pieces.dropLast() {
            guard let bit = available[word], mask & bit == 0 else { throw error }
            mask |= bit
        }
        guard (mask & UInt32(cmdKey | controlKey | optionKey)) != 0 else { throw error }
        character = key
        modifiers = mask
    }

    @MainActor
    func keyCode() -> UInt32? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue() else { return nil }
        return keyCode(in: source)
    }

    @MainActor
    func keyCode(in source: TISInputSource) -> UInt32? {
        guard let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = unsafeBitCast(property, to: CFData.self)
        guard let bytes = CFDataGetBytePtr(data) else { return nil }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        // On layouts such as French, a digit may only exist on the shifted layer.
        let layers: [UInt32] = modifiers & UInt32(shiftKey) != 0 ? [UInt32(shiftKey >> 8), 0] : [0]
        for layer in layers {
            for code in UInt16(0)..<128 {
                var deadKey: UInt32 = 0
                var count = 0
                var output = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(layout, code, UInt16(kUCKeyActionDown), layer,
                                            UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysMask),
                                            &deadKey, output.count, &count, &output)
                if status == noErr, String(decoding: output.prefix(count), as: UTF16.self).lowercased() == String(character) {
                    return UInt32(code)
                }
            }
        }
        return nil
    }
}

@MainActor
final class EditorHotkeys {
    private static let signature: OSType = 0x4e4f5445 // NOTE
    private let notes: EditorHotkey?
    private let global: EditorHotkey?
    private let noteActions: EditorHotkey?
    private let openPalette: () -> Void
    private let openNoteActions: () -> Void
    private var eventHandler: EventHandlerRef?
    private var notesRef: EventHotKeyRef?
    private var globalRef: EventHotKeyRef?
    private var actionsRef: EventHotKeyRef?
    private var inputSourceObserver: NSObjectProtocol?
    private var attemptedNotes = false
    private var watching = false

    init(notes: EditorHotkey?, global: EditorHotkey?, noteActions: EditorHotkey?,
         openPalette: @escaping () -> Void, openNoteActions: @escaping () -> Void) {
        self.notes = notes
        self.global = global
        self.noteActions = noteActions
        self.openPalette = openPalette
        self.openNoteActions = openNoteActions
    }

    func start() {
        guard !watching, notes != nil || global != nil || noteActions != nil else { return }
        var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, data in
            guard let event, let data else { return OSStatus(eventNotHandledErr) }
            var hotkey = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                    nil, MemoryLayout<EventHotKeyID>.size, nil, &hotkey) == noErr else {
                return OSStatus(eventNotHandledErr)
            }
            let target = Unmanaged<EditorHotkeys>.fromOpaque(data).takeUnretainedValue()
            return MainActor.assumeIsolated { target.fire(hotkey) }
        }, 1, &pressed, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
        guard status == noErr else {
            EditorDiagnostics.record(.shortcutStartupFailed)
            Output.error("Could not start Notes shortcuts.")
            return
        }
        watching = true
        inputSourceObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.rebind() } }
        rebind()
    }

    private func rebind() {
        guard watching else { return }
        unregisterShortcuts()
        if let global { globalRef = register(global, id: 2) }
        refresh()
    }

    func refresh() {
        guard watching, notes != nil || noteActions != nil else { return }
        if NotesEditorAccess.frontmostPID() != nil {
            guard !attemptedNotes else { return }
            attemptedNotes = true
            if let notes { notesRef = register(notes, id: 1) }
            if let noteActions { actionsRef = register(noteActions, id: 3) }
        } else {
            attemptedNotes = false
            if let notesRef { UnregisterEventHotKey(notesRef); self.notesRef = nil }
            if let actionsRef { UnregisterEventHotKey(actionsRef); self.actionsRef = nil }
        }
    }

    func stop() {
        watching = false
        if let inputSourceObserver {
            DistributedNotificationCenter.default().removeObserver(inputSourceObserver)
            self.inputSourceObserver = nil
        }
        unregisterShortcuts()
        if let eventHandler { RemoveEventHandler(eventHandler); self.eventHandler = nil }
    }

    private func unregisterShortcuts() {
        attemptedNotes = false
        if let notesRef { UnregisterEventHotKey(notesRef); self.notesRef = nil }
        if let globalRef { UnregisterEventHotKey(globalRef); self.globalRef = nil }
        if let actionsRef { UnregisterEventHotKey(actionsRef); self.actionsRef = nil }
    }

    private func register(_ shortcut: EditorHotkey, id: UInt32) -> EventHotKeyRef? {
        guard let key = shortcut.keyCode() else {
            EditorDiagnostics.record(.shortcutLayoutUnsupported)
            Output.error("The current keyboard layout does not have the configured shortcut key.")
            return nil
        }
        var result: EventHotKeyRef?
        let status = RegisterEventHotKey(key, shortcut.modifiers, EventHotKeyID(signature: Self.signature, id: id),
                                         GetApplicationEventTarget(), 0, &result)
        guard status == noErr else {
            EditorDiagnostics.record(.shortcutRegistrationFailed)
            let name = id == 3 ? "note actions" : (id == 1 ? "Notes search" : "global search")
            Output.error("Could not register the \(name) shortcut. Choose a different shortcut.")
            return nil
        }
        return result
    }

    private func fire(_ hotkey: EventHotKeyID) -> OSStatus {
        guard hotkey.signature == Self.signature else { return OSStatus(eventNotHandledErr) }
        if hotkey.id == 1, notesRef != nil, NotesEditorAccess.frontmostPID() != nil {
            openPalette()
            return noErr
        }
        if hotkey.id == 2, globalRef != nil {
            openPalette()
            return noErr
        }
        if hotkey.id == 3, actionsRef != nil, NotesEditorAccess.frontmostPID() != nil {
            // Menu tracking must not start within the Carbon event callback.
            DispatchQueue.main.async { [weak self] in self?.openNoteActions() }
            return noErr
        }
        return OSStatus(eventNotHandledErr)
    }
}
