import ApplicationServices
import CoreGraphics
import XCTest
@testable import notescli

final class EditorTypingOptionsTests: XCTestCase {
    func testFastSlashAcceptsOnlyAnExactRecentBuiltInCommand() {
        var sequence = EditorSlashSequence()
        sequence.start(now: 1)
        sequence.append("h", now: 1.01)
        XCTAssertNil(sequence.exactCommand(now: 1.02))
        sequence.append("2", now: 1.02)
        XCTAssertEqual(sequence.exactCommand(now: 1.03)?.literal, "/h2")
        XCTAssertEqual(sequence.exactCommand(now: 1.03)?.choice.action, .format(.heading))
        XCTAssertNil(sequence.exactCommand(now: 1.5))
        sequence.append("x", now: 1.03)
        XCTAssertNil(sequence.exactCommand(now: 1.04))
        sequence.start(now: 2)
        sequence.append("h", now: 2.01)
        sequence.append(nil, now: 2.02)
        sequence.append("2", now: 2.03)
        XCTAssertNil(sequence.exactCommand(now: 2.04))
    }

    func testRejectedFastSlashOnlyReplaysReturnAtTheUnchangedCaret() {
        MainActor.assumeIsolated {
            let editor = AXUIElementCreateApplication(getpid())
            let caret = NotesEditorSelection(pid: getpid(), noteID: UUID(), editor: editor,
                                             window: editor, location: 3, length: 0)
            let otherWindow = NotesEditorSelection(pid: caret.pid, noteID: caret.noteID, editor: editor,
                                                    window: AXUIElementCreateSystemWide(), location: 3, length: 0)
            let command = EditorTrigger(kind: .slash("h2"), literal: "/h2", range: NSRange(location: 0, length: 3))
            let changed = EditorTrigger(kind: .slash("h3"), literal: "/h3", range: command.range)
            @MainActor func replays(applied: Bool = false, before: NotesEditorSelection?,
                         after: NotesEditorSelection? = nil, current: EditorTrigger?) -> Bool {
                var focus = before
                var didReplay = false
                EditorSlashReturn.finish(caret: caret, trigger: command, commit: { applied }, selection: { focus },
                                         readTrigger: { _ in focus = after ?? before; return current },
                                         replay: { didReplay = true })
                return didReplay
            }
            XCTAssertTrue(replays(before: caret, current: command))
            XCTAssertFalse(replays(applied: true, before: caret, current: command))
            XCTAssertFalse(replays(before: otherWindow, current: command))
            XCTAssertFalse(replays(before: caret, after: otherWindow, current: command))
            XCTAssertFalse(replays(before: caret.covering(NSRange(location: 4, length: 0)), current: command))
            XCTAssertFalse(replays(before: caret, current: changed))
            XCTAssertFalse(replays(before: caret, current: nil))
        }
    }

    func testTypingListenerRecoversOnTheSameNotesPIDAfterMacOSDisablesIt() {
        var recovery = EditorKeyTapRecovery()
        XCTAssertEqual(recovery.action(for: 21, interceptNavigation: true, listener: .missing, now: 5), .install)
        XCTAssertEqual(recovery.action(for: 21, interceptNavigation: true, listener: .enabled, now: 5.1), .none)
        XCTAssertEqual(recovery.action(for: 21, interceptNavigation: true, listener: .disabled, now: 5.2), .none)
        XCTAssertEqual(recovery.action(for: 21, interceptNavigation: true, listener: .disabled, now: 6.2), .resume)
        XCTAssertEqual(recovery.action(for: 21, interceptNavigation: true, listener: .missing, now: 6.3), .none)
        XCTAssertEqual(recovery.action(for: 21, interceptNavigation: true, listener: .missing, now: 7.3), .install)
        XCTAssertEqual(recovery.action(for: nil, interceptNavigation: true, listener: .enabled, now: 7.4), .stop)
        XCTAssertEqual(recovery.action(for: 21, interceptNavigation: true, listener: .missing, now: 7.5), .install)
    }

    func testTypingListenerRetriesFailedInstallWithoutChurning() {
        var recovery = EditorKeyTapRecovery()
        XCTAssertEqual(recovery.action(for: 21, interceptNavigation: false, listener: .missing, now: 10), .install)
        XCTAssertEqual(recovery.action(for: 21, interceptNavigation: false, listener: .missing, now: 10.9), .none)
        XCTAssertEqual(recovery.action(for: 21, interceptNavigation: false, listener: .missing, now: 11), .install)
        XCTAssertEqual(recovery.action(for: 21, interceptNavigation: true, listener: .missing, now: 11.1), .install)
        XCTAssertEqual(recovery.action(for: 22, interceptNavigation: true, listener: .enabled, now: 11.2), .install)
    }

    func testMarkdownConvertsAnExistingLineWithoutIncludingItsTextInTheReplacement() {
        for (marker, action): (String, NotesEditorAction) in [("- ", .dashed), ("* ", .bulleted), ("## ", .heading)] {
            let prefix = "Previous line 😀\n" + marker
            let caret = prefix.utf16.count
            let trigger = EditorTrigger.parse(prefix: prefix, endingAt: caret, atDocumentStart: true,
                                              nextUnit: "T", allowMarkdown: true)
            XCTAssertEqual(trigger?.kind, .markdown(action))
            XCTAssertEqual(trigger?.range, NSRange(location: caret - marker.utf16.count, length: marker.utf16.count))
            XCTAssertNil(EditorTrigger.parse(prefix: prefix, endingAt: caret, atDocumentStart: true,
                                             nextUnit: "T", allowMarkdown: false))
        }
    }

    func testSlashDetectionUsesTheTypedCharacterAndKeepsModifiedShortcutsNative() {
        MainActor.assumeIsolated {
            XCTAssertEqual(EditorKeyTap.key(flags: .maskShift, code: 26, typedSlash: true), .slash)
            XCTAssertEqual(EditorKeyTap.key(flags: .maskAlternate, code: 44, typedSlash: true), .slash)
            XCTAssertEqual(EditorKeyTap.key(flags: .maskCommand, code: 44, typedSlash: true), .other)
            XCTAssertEqual(EditorKeyTap.key(flags: .maskControl, code: 44, typedSlash: true), .other)
            XCTAssertEqual(EditorKeyTap.key(flags: [], code: 44, typedSlash: false), .other)
            XCTAssertEqual(EditorKeyTap.key(flags: [], code: 36, typedSlash: false), .accept)
            XCTAssertEqual(EditorKeyTap.key(flags: .maskShift, code: 36, typedSlash: false), .other)
        }
    }

    func testSlashCommandsCanBeDisabledOnTheirOwn() throws {
        let options = try parse("--no-slash-commands")
        XCTAssertNil(trigger("/h2", options))
        XCTAssertNil(trigger("/My Template", options))
        XCTAssertEqual(trigger("## ", options)?.kind, .markdown(.heading))
        XCTAssertTrue(options.isEnabled)
        XCTAssertFalse(options.interceptsSlashKeys)
    }

    func testMarkdownCanBeDisabledOnItsOwn() throws {
        let options = try parse("--no-markdown-shortcuts")
        XCTAssertNil(trigger("# ", options))
        XCTAssertEqual(trigger("/h2", options)?.kind, .slash("h2"))
        XCTAssertEqual(trigger("/My Template", options)?.kind, .slash("My Template"))
        XCTAssertTrue(options.isEnabled)
        XCTAssertTrue(options.interceptsSlashKeys)
    }

    func testSpecificMarkdownExclusionsDoNotAffectSlashOrOtherExpansions() throws {
        let options = try parse("--disable-markdown", "title, quote")
        XCTAssertNil(trigger("# ", options))
        XCTAssertNil(trigger("> ", options))
        XCTAssertEqual(trigger("## ", options)?.kind, .markdown(.heading))
        XCTAssertEqual(trigger("/title", options)?.kind, .slash("title"))
        XCTAssertEqual(trigger("/quote", options)?.kind, .slash("quote"))
    }

    func testExcludingEveryExpansionLeavesOnlySlashCommands() throws {
        let options = try parse("--disable-markdown", "title,heading,subheading,checklist,monostyled,quote,dashed,bulleted,numbered")
        XCTAssertTrue(options.isEnabled)
        XCTAssertTrue(options.markdownActions.isEmpty)
        XCTAssertEqual(trigger("/h2", options)?.kind, .slash("h2"))

        let disabled = try parse("--no-slash-commands", "--disable-markdown",
                                 "title,heading,subheading,checklist,monostyled,quote,dashed,bulleted,numbered")
        XCTAssertFalse(disabled.isEnabled)
        XCTAssertFalse(disabled.interceptsSlashKeys)
    }

    func testInvalidMarkdownExclusionListsAreRejected() {
        for invalid in ["", "unknown", "bold", "title,title", "heading,", ",quote"] {
            XCTAssertThrowsError(try NotesCLI.parseAsRoot(["editor", "--disable-markdown", invalid]), "'\(invalid)'") {
                XCTAssertTrue(NotesCLI.message(for: $0).contains("Use distinct Markdown shortcut names:"))
            }
        }
    }

    func testLegacyMasterSwitchAndSeparateSwitchesCanTurnOffAllTyping() throws {
        for flags in [
            ["--no-typing-shortcuts"],
            ["--no-typing-shortcuts", "--disable-markdown", "quote"],
            ["--no-markdown-shortcuts", "--no-slash-commands"]
        ] {
            let options = try parse(flags)
            XCTAssertFalse(options.isEnabled)
            XCTAssertFalse(options.interceptsSlashKeys)
            XCTAssertNil(trigger("/h2", options))
            XCTAssertNil(trigger("/My Template", options))
            XCTAssertNil(trigger("## ", options))
        }
    }

    func testLegacySlashKeySwitchKeepsSlashAndMarkdownTriggers() throws {
        let options = try parse("--no-slash-keys")
        XCTAssertFalse(options.interceptsSlashKeys)
        XCTAssertEqual(trigger("/h2", options)?.kind, .slash("h2"))
        XCTAssertEqual(trigger("## ", options)?.kind, .markdown(.heading))
    }

    func testDefaultsKeepSlashNavigationAndRequireSpaceForMarkdown() throws {
        let options = try parse()
        XCTAssertTrue(options.interceptsSlashKeys)
        XCTAssertEqual(trigger("/h2", options, afterSpace: false)?.kind, .slash("h2"))
        XCTAssertNil(trigger("## ", options, afterSpace: false))
        XCTAssertEqual(trigger("## ", options)?.kind, .markdown(.heading))
    }

    private func parse(_ flags: String...) throws -> EditorTypingOptions {
        try parse(flags)
    }

    private func parse(_ flags: [String]) throws -> EditorTypingOptions {
        try XCTUnwrap(NotesCLI.parseAsRoot(["editor"] + flags) as? EditorCommand).typingOptions
    }

    private func trigger(_ prefix: String, _ options: EditorTypingOptions, afterSpace: Bool = true) -> EditorTrigger? {
        EditorTrigger.parse(prefix: prefix, endingAt: prefix.utf16.count, atDocumentStart: true, nextUnit: nil,
                            allowMarkdown: afterSpace, allowTemplateQuery: true, typing: options)
    }
}
