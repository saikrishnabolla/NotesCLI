# notescli spec (Mac, v1)

A Swift CLI and MCP server for Apple Notes on macOS 14+. Goal: match every feature of the existing
Notes CLIs and MCP servers (see PARITY.md), then do better on fidelity and safety.

## Shape
- `NotesCore` (pure Swift, no Apple-only frameworks): model, protobuf body decoding, Markdown/HTML/plain renderers, Markdown parsing.
- `NotesStore` (macOS): `NotesReading` over a read-only snapshot of NoteStore.sqlite.
- `NotesAutomation` (macOS): `NotesWriting` through Notes.app scripting (AppleScript/JXA via osascript or NSAppleScript).
- `NotesNative` (macOS): opt-in rich writes through Apple's private Notes framework.
- `NotesSafety`: write allowlists, concurrency checks, journal entries, and snapshots.
- `NotesIndex` and `NotesSync`: local search, export, and Markdown synchronization.
- `NotesMCP`: MCP server over stdio exposing the same operations.
- `notescli`: CLI (swift-argument-parser). Every read command supports `--json`. Errors print a JSON `NotesError` on stderr with `--json`.

## Data facts verified on this Mac (macOS 27.2)
- DB: `~/Library/Group Containers/group.com.apple.notes/NoteStore.sqlite` (+ live -wal/-shm). Needs Full Disk Access.
- Entities via Z_PRIMARYKEY (Z_ENT numbers vary by macOS; look them up by Z_NAME, never hard-code): ICNote, ICFolder, ICAccount, ICAttachment, ICInlineAttachment, ICMedia, ICHashtag, ICNoteData.
- Note bodies: `ZICNOTEDATA.ZDATA` is gzip; inside is protobuf (NoteStoreProto > Document > Note: note_text + attribute_run).
  Reference decoder: threeplanetssoftware/apple_cloud_notes_parser (proto/notestore.proto), also coddingtonbear/icloud-md proto/.
- Locked notes: ZISPASSWORDPROTECTED = 1; body unreadable. Report them, never fail on them.

## Rules
- Reads never write to NoteStore.sqlite. Copy db + wal + shm to a private temp dir, open read-only there, delete the copy after. Do not open the live DB with write flags.
- Scripting is the default write engine. Native writes run only with `--engine native`, `NOTESCLI_ENGINE=native`, or MCP `--allow-native`.
- The native engine uses Apple's private Notes framework and Notes' persistent Core Data store. It can break after a macOS update. Run the native doctor first and keep backups.
- Never modify NoteStore.sqlite with SQL.
- Every write is read back from a fresh snapshot and reported as `verified`, `unverified`, or `unknown` (timeouts). Never retry a write whose outcome is unknown.
- Every write honors read-only mode, dry-run, write-folder allowlists, concurrency guards, the write journal, and snapshots. Snapshots with attachments are not restorable.
- Delete means move to Recently Deleted. No hard delete.
- Live write tests touch real iCloud data: they run ONLY inside a folder named `notescli-test` in the default account, use titles prefixed `notescli-test-`, and delete what they create. Live tests are opt-in via `NOTESCLI_LIVE_TESTS=1`; default `swift test` must not touch Notes.
- Never print or commit note contents from the user's library into fixtures, logs, or docs. Fixtures are synthetic or made from notes the tests created.
