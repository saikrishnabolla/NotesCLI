# Command reference

This reference follows `notescli --help` from version 1.1.1.

## Global options

```text
--backend <backend>  Backend: default or fake. Also accepts NOTESCLI_BACKEND.
--engine <engine>    Write engine: scripting or native. Also accepts NOTESCLI_ENGINE.
--read-only          Refuse all writes.
--json               Print JSON, including errors on stderr.
--quiet              Suppress non-essential human output. Errors still print.
--version            Show the version.
-h, --help           Show help information.
```

Use `--json` for scripts and agents. A note reference can be `#123`, a UUID, Core Data ID, short ID such as `n123`, bare numeric ID such as `123`, or an exact title. `#123` and `123` also match a note titled exactly `#123` or `123`; when they match one note by number and another by title, the command fails with `ambiguous_reference` and lists both. Use `id:123` (or `n123`) to match only the note number or ID, and `title:#123` to match only the exact title. Numbers come from Notes' stable `Z_PK` value and appear as `#ID` in human listings and `number` in JSON.

With no command, a terminal shows the NotesCLI home screen and the titles of five recently edited notes. `notescli --no-recent` or `NOTESCLI_HOME_RECENT=0` hides the titles. Redirected output shows plain help. `notescli --json` returns the home data as JSON; each recent note has only its number, title, folder, and modified date.

## Read commands

```text
notescli accounts
notescli folders [--account <account>] [--tree]
notescli list [--folder <folder>] [--account <account>] [--pinned]
              [--tag <tag>] [--since <since>] [--until <until>]
              [--has image|audio|pdf|scan|drawing|table|checklist|link|file]
              [--cursor <cursor>]
              [--limit <limit>] [--sort modified|created|opened|title|display]
              [--include-deleted]
notescli show <ref> [--format markdown|text|html|json|outline] [--no-attachments]
notescli show-many <refs> ... [--format markdown|text|html|json]
notescli search <query> [--folder <folder>] [--limit <limit>]
                [--has image|audio|pdf|scan|drawing|table|checklist|link|file]
                [--cursor <cursor>] [--fuzzy | --index] [--rebuild]
notescli tags
notescli recent [<n>] [--limit <limit>]
notescli pinned [--limit <limit>]
notescli capabilities
notescli fetch <ref> | --all [--wait <seconds>]
notescli index [--rebuild] [--background | --status | --cancel]
notescli stats
notescli count [--folder <folder>] [--account <account>] [--include-deleted]
notescli selection
notescli deeplink <ref>
notescli backlinks <ref>
notescli attachments <ref> [--save <directory> | --preview <directory>]
notescli table show <ref> [--attachment <id>] [--format markdown|json|csv]
notescli anchor add <ref> (--heading <text> | --offset <utf16-offset>)
notescli anchor list [<ref>]
notescli anchor resolve <id>
notescli anchor prune
notescli wait-sync <ref> [--timeout <seconds>]
notescli raw <ref>
notescli deleted
notescli smart-folders [--evaluate]
notescli help [<command>]
notescli open <ref>
notescli open <account> --account
notescli open <folder> --folder
notescli open <note> --attachment <id> [--reveal]
```

`recent` defaults to 10 notes. `list` excludes Recently Deleted unless you pass `--include-deleted`. `list` and `search` return an opaque `nextCursor` in JSON when more results exist. Pass it back with `--cursor`; it stores the sort key and note ID instead of an offset.

`show --format outline` returns a heading tree with UTF-16 offsets. Anchors are stored in `~/Library/Application Support/NotesCLI/anchors.sqlite` and relocate from a saved text fingerprint after edits. `wait-sync` succeeds only after the store reports that the latest local version reached iCloud and no save flags remain.

Attachment previews are PNG files: resized images, the first video frame, or the first PDF page. Classic `com.apple.drawing` strokes render as SVG when stroke data is present. If decoding fails, the attachment keeps its raster fallback path. Mention output includes the stored participant name, email, and user ID when available.

## Note writes

```text
notescli add [<title>] [--folder <folder>] [--body <body> | --stdin | --file <file>]
             [--attach <file> ...]
notescli append <ref> [--body <body> | --stdin]
notescli edit <ref>
notescli rename <ref> <title>
notescli move <ref> <folder>
notescli delete <refs> ... [--yes]
notescli prepend <ref> [--body <body> | --stdin]
notescli insert-under-heading <ref> <heading> [--body <body> | --stdin]
notescli replace-section <ref> <heading> [--body <body> | --stdin]
notescli replace-text <ref> <find> <replacement>
notescli clip <url> [--folder <folder>]
```

`add` opens `$EDITOR` when no body source is given. `add --attach` requires `--engine native` and creates the note and attachments in one save. Native `edit` preserves attachments named by `notescli-attachment:ID`; scripting `edit` still refuses attachment loss. `delete` moves notes to Recently Deleted.

## Folder writes

```text
notescli folder create <name> [--parent <parent>] [--account <account>]
notescli folder rename <ref> <name>
notescli folder move <ref> [<parent>] [--account <account>]
notescli folder delete <ref> [--yes] [--expect-count <count>]
notescli folder exists <path>
notescli smart-folder create <name> --tags <a,b> --match any|all
notescli smart-folder rename <ref> <name> --expected-count <count>
notescli smart-folder delete <ref> --expected-count <count>
```

Deleting a folder moves its notes to Recently Deleted.

## Rich writes

These commands require `--engine native` unless a scripting path is listed:

```text
notescli checklist add|toggle|check-all|uncheck-all|clear-done|list ...
notescli pin <ref>
notescli unpin <ref>
notescli tag add|remove|rename|delete ...
notescli link add|add-url|list ...
notescli text insert|delete|replace|find ...
notescli format paragraph|inline ...
notescli attach <ref> <path> [--position <position>] [--view <view>]
notescli attach <ref> --pasteboard [--position <position>] [--view <view>]
notescli attachment delete <ref> <attachment-id>
notescli recording add <ref> --file <audio> [--transcribe | --transcript-file <json>] [--title <title>] [--locale <locale>]
notescli recording create --folder <folder> --title <title> --file <audio> [--transcribe | --transcript-file <json>] [--locale <locale>]
notescli recording transcribe-file --file <audio> --output <json> [--locale <locale>]
notescli recording transcribe <ref> [--attachment <id>] [--locale <locale>] [--transcript-file <json>]
notescli recording transcript <ref> [--format text|srt|vtt|json]
notescli drawing add <ref> --svg <file> [--ink pen|marker|pencil|monoline]
                [--width <width>] [--color <hex>] [--bw] [--size <width>x<height>]
                [--fit contain|stretch] [--fill outline|hatch]
notescli drawing create --folder <folder> --title <title> --svg <file> [drawing options]
notescli drawing export <ref> [--attachment <id>] [--format svg|png] [--output <file>]
notescli table create|set|add-row|add-column|remove-row|remove-column ...
notescli duplicate <ref> [--title <title>]
notescli restore <ref> [--folder <folder>]
notescli write <ref> [--body <body> | --stdin | --file <file>] [--backup]
```

`link add-url --card` creates a native URL preview. File and pasteboard attachments are copied to private temporary storage, hashed, and checked against the stored media. Recording input is converted to M4A with AVFoundation. `recording transcribe-file` writes timed JSON without opening Notes. `--transcript-file` imports that JSON into a native Notes transcript; each segment's `fragment` index picks the audio fragment it belongs to, and 0 is the default. `recording transcribe` transcribes each fragment of a recording in order. Readback checks each segment's text, timing, speaker, and fragment. On-device transcription stays on the Mac. Drawing commands convert SVG paths and shapes to editable `com.apple.paper` PencilKit strokes. PNG export requires `--output`; SVG prints to standard output when no output path is set. `write` uses scripting by default. Restore, Smart Folder changes, and folder moves require native opt-in. Write results include `engine` and `operationID`.

## Diagrams

```text
notescli diagram add <note> --file <diagram.svg|diagram.html>
        [--as image|drawing] [--width <pixels>] [--scale 2|3]
        [--background white|transparent|auto] [--dark]
notescli diagram create --folder <folder> --title <title> --file <diagram.svg|diagram.html>
        [--as image|drawing] [--width <pixels>] [--scale 2|3]
        [--background white|transparent|auto] [--dark]
notescli diagram export <note> --output <file> [--attachment-id <id>]
```

Image mode is the default. WebKit renders the file with JavaScript off and no file or network access: only inline styles and `data:` images and fonts load, so linked web fonts fall back to installed fonts. Rendering stops after 30 seconds, and files over 5 MB or 50,000 elements are refused. WebKit crops the page to its visible content, renders at 700 pixels and 2x scale by default, and inserts one PNG through the native frozen-byte path. The PNG contains the original SVG or HTML in an iTXt chunk. `diagram export` recovers it; pass `--attachment-id` when a note has more than one diagram.

`--background auto` keeps an opaque source background. A transparent source gets a white fallback, or a dark fallback with `--dark`. Notes does not invert images in dark mode. `--background transparent` clears the page background but leaves any background drawn inside the SVG. `--as drawing` accepts SVG and converts its supported shapes and paths to editable Paper strokes at the requested width. Outline text before conversion because SVG text nodes are not PencilKit strokes.

All write commands accept `--dry-run`, `--idempotency-key`, `--write-folders`, `--if-modified`, `--expect-revision`, `--allow-shared`, `--wait-sync`, and `--sync-timeout`. Shared-note writes require native mode and Notes write permission. A sync timeout leaves the write verified and returns `syncPending: true`. Body rewrites also accept `--allow-attachment-loss`.

## Safety and sync

```text
notescli exists <ref>
notescli history <ref>
notescli diff <ref> [<snapshot>]
notescli undo <ref>
notescli revert <ref> [<snapshot>]
notescli journal list [--limit <limit>]
notescli journal resolve [<operation-ids> ...]
notescli sync <directory> --folder <folder> [--propagate-deletes] [--dry-run]
notescli sync-daemon <directory> --folder <folder> [--interval <seconds>]
notescli watch [--folder <folder>]
notescli file pull <note> <path> [--dry-run]
notescli file push <path> [--dry-run]
notescli file diff <path>
```

`undo` and `revert` accept a note reference for snapshots or a journal operation ID for a recorded setting or Smart Folder rule preimage.
Snapshots with native-only features require `--engine native`. Pass `--allow-downgrade` to permit scripting conversion. Native restore verifies the saved structure through a fresh database read.

## Export

```text
notescli export [--out <out>] [--folder <folder>]
                [--format markdown|html|json|ndjson|sqlite|zip|pdf|docx|rtf|epub|bear|joplin|quiver]
                [--attachments] [--embed-media] [--template <template>]
                [--filename-template <template>] [--obsidian] [--prune]
                [--combine] [--scans-pdf]
                [--order display|modified|created|title]
```

The default output directory is `notes-export`. `--combine` writes one PDF per folder. EPUB writes one book per folder. Export order defaults to Notes display order.

## Setup and diagnostics

```text
notescli setup
notescli permissions
notescli doctor
notescli capabilities
notescli completion [zsh|bash|fish]
```

`setup` connects supported MCP clients and opens permission settings. `permissions` opens Full Disk Access and requests Notes Automation and Speech Recognition access.

## MCP

```text
notescli mcp [--allow-native]
notescli mcp install [--client claude-code|claude-desktop|codex|cursor|vscode|tailscale|all] [--read-only] [--allow-native] [--write-folders FOLDERS]
notescli mcp uninstall [--client claude-code|claude-desktop|codex|cursor|vscode|tailscale|all]
notescli mcp status [--client claude-code|claude-desktop|codex|cursor|vscode|tailscale|all]
notescli mcp token show|rotate
```

Running `notescli mcp` with no subcommand starts the stdio server. Client selection defaults to `all`.
