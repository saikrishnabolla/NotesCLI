# notescli spec (Mac, v1)

A Swift CLI and MCP server for Apple Notes on macOS 14+. Goal: match every feature of the existing
Notes CLIs and MCP servers (see PARITY.md), then do better on fidelity and safety.

## Shape
- `NotesCore` (pure Swift, no Apple-only frameworks): model, protobuf body decoding, Markdown/HTML/plain renderers, Markdown parsing.
- `NotesStore` (macOS): `NotesReading` over a read-only snapshot of NoteStore.sqlite.
- `NotesAutomation` (macOS): `NotesWriting` through Notes.app scripting (AppleScript/JXA via osascript or NSAppleScript).
- `NotesNative` (macOS): default rich writes through Apple's private Notes framework.
- `NotesSafety`: write allowlists, concurrency checks, journal entries, and snapshots.
- `NotesIndex` and `NotesSync`: local search, export, and Markdown synchronization.
- `NotesMCP`: MCP server over stdio or authenticated Streamable HTTP over Tailscale, exposing the same operations.
- `notescli`: CLI (swift-argument-parser). Every read command supports `--json`. Errors print a JSON `NotesError` on stderr with `--json`.

## Data facts verified on this Mac (macOS 27.2)
- DB: `~/Library/Group Containers/group.com.apple.notes/NoteStore.sqlite` (+ live -wal/-shm). Needs Full Disk Access.
- Entities via Z_PRIMARYKEY (Z_ENT numbers vary by macOS; look them up by Z_NAME, never hard-code): ICNote, ICFolder, ICAccount, ICAttachment, ICInlineAttachment, ICMedia, ICHashtag, ICNoteData.
- Note bodies: `ZICNOTEDATA.ZDATA` is gzip; inside is protobuf (NoteStoreProto > Document > Note: note_text + attribute_run).
  Reference decoder: threeplanetssoftware/apple_cloud_notes_parser (proto/notestore.proto), also coddingtonbear/icloud-md proto/.
- Locked notes: ZISPASSWORDPROTECTED = 1. A supplied password unlocks V1 and V1 Neo bodies and attachments; device-key/passcode V2 remains unsupported. Without a password, report them without failing.

## Rules
- Reads never write to NoteStore.sqlite. Copy db + wal + shm to a private temp dir, open read-only there, delete the copy after. Do not open the live DB with write flags.
- Native is the default write engine when an operation has a native implementation. `--engine scripting` or `NOTESCLI_ENGINE=scripting` selects scripting explicitly. Operations without a native implementation fall back to scripting. If the native framework is unavailable, plain writes fall back to scripting; rich and native-only writes stop instead of losing content. Write-enabled MCP servers expose native tools by default; read-only servers hide all write tools.
- The native engine uses Apple's private Notes framework and Notes' persistent Core Data store. It can break after a macOS update. Run the native doctor first and keep backups.
- Never modify NoteStore.sqlite with SQL.
- Every write is read back from a fresh snapshot and reported as `verified`, `unverified`, `unknown` (timeouts), or `rolled_back` (a failed native create whose partial note was moved to Recently Deleted). Never retry a write whose outcome is unknown.
- Every write honors read-only mode, dry-run, write-folder allowlists, concurrency guards, the write journal, and snapshots. Native restore keeps exact saved attachment rows when they remain in Notes, recreates supported attachment graphs from verified archived bytes, and refuses unknown future graphs.
- Delete means move to Recently Deleted. No hard delete.
- Live write tests touch real iCloud data: they run ONLY inside a folder named `notescli-test` in the default account, use titles prefixed `notescli-test-`, and delete what they create. Live tests are opt-in via `NOTESCLI_LIVE_TESTS=1`; default `swift test` must not touch Notes.
- Never print or commit note contents from the user's library into fixtures, logs, or docs. Fixtures are synthetic or made from notes the tests created.
