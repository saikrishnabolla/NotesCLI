# Command reference

This reference follows `notescli --help` from Notes CLI 1.1.12.

`notescli report create --title TITLE --file REPORT.md [--folder FOLDER] [--tags TAGS] [--replace]` creates and verifies one native report. `--replace` updates the report with the same title in the target folder, or creates it on the first run. Markdown may include local or HTTPS images, bare-URL preview cards, native tables, tags, checklists, attachments, citations, and dividers. Reports render `svg`, `diagram`, `html diagram`, and `mermaid` fences. If rendering fails, the fence stays as code. Plain `html` fences always stay as code.

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

With no command, a terminal shows the Notes CLI home screen and the titles of five recently edited notes. `notescli --no-recent` or `NOTESCLI_HOME_RECENT=0` hides the titles. Redirected output shows plain help. `notescli --json` returns the home data as JSON; each recent note has only its number, title, folder, and modified date.

## Read commands

```text
notescli accounts [--set-default <account>]
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
notescli collaboration activity <ref> [--limit <1-500>]
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
notescli ocr <ref> [--attachment <id>] [--language <language> ...] [--title <title>]
notescli help [<command>]
notescli open <ref>
notescli open <account> --account
notescli open <folder> --folder
notescli open <note> --attachment <id> [--reveal]
```

`recent` defaults to 10 notes. `list` excludes Recently Deleted unless you pass `--include-deleted`. `list` and `search` return an opaque `nextCursor` in JSON when more results exist. Pass it back with `--cursor`; it stores the sort key and note ID instead of an offset.

`show --format outline` returns a heading tree with UTF-16 offsets. Anchors are stored in `~/Library/Application Support/NotesCLI/anchors.sqlite` and relocate from a saved text fingerprint after edits. `wait-sync` succeeds only after the store reports that the latest local version reached iCloud and no save flags remain.

`collaboration activity` is read-only. It returns the stored activity blob and each reachable event with byte counts, SHA-256 hashes, bounded base64, and JSON only when the raw payload parses as JSON. Unknown and future event formats stay raw.

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

`add` opens `$EDITOR` when no body source is given. `add --attach` uses the native engine and creates the note and attachments in one save. Native `edit` preserves attachments named by `notescli-attachment:ID`; scripting `edit` still refuses attachment loss. `delete` moves notes to Recently Deleted.

## Folder writes

```text
notescli folder create <name> [--parent <parent>] [--account <account>]
notescli folder rename <ref> <name>
notescli folder move <ref> [<parent>] [--account <account>]
notescli folder delete <ref> [--yes] [--expect-count <count>]
notescli folder exists <path>
notescli folder sort <ref> [--by default|modified|created|title] [--direction newest|oldest|ascending|descending]
notescli folder group-by-date <ref> [--enabled true|false]
notescli smart-folder create <name> --tags <a,b> --match any|all
notescli smart-folder rename <ref> <name> --expected-count <count>
notescli smart-folder edit-rules <ref> --query-json <json> --expected-count <count>
notescli smart-folder edit-typed <ref> --expected-count <count> [typed filters]
notescli smart-folder delete <ref> --expected-count <count>
```

Deleting a folder moves its notes to Recently Deleted.

## Rich writes

These commands use the default native engine unless a scripting path is listed:

```text
notescli checklist add|toggle|check-all|uncheck-all|clear-done|list ...
notescli checklist auto-sort [--enabled true|false]
notescli pin <ref>
notescli unpin <ref>
notescli tag add|remove|rename|delete ...
notescli link add <ref> <target> [--text <text>] [--paragraph-id <uuid>] [--paragraph-name <name>]
notescli link add-url|list ...
notescli text insert|delete|replace|find ...
notescli format paragraph|inline|divider|math|mention ...
notescli math evaluate <expression>
notescli math insert-result <ref> <expression> [--position <position>]
notescli attach <ref> <path> [--position <position>] [--view <view>]
notescli attach <ref> --pasteboard [--position <position>] [--view <view>]
notescli map add <ref> <https://maps.apple.com/...> [--position <position>]
notescli scan add <ref> <image> ... [--position <position>]
notescli settings show
notescli settings sort [--set modified|created|title]
notescli settings group-by-date [--enabled true|false]
notescli settings default-text-size [--points 10|12|14|18|24]
notescli settings resume-quick-note [--enabled true|false]
notescli settings auto-convert-tags [--enabled true|false]
notescli settings default-style [--set title|heading|subheading|body]
notescli settings query-date-grouping [--enabled true|false]
notescli settings auto-format-markdown [--enabled true|false]
notescli settings dark-backgrounds [--enabled true|false]
notescli settings show-note-count [--enabled true|false]
notescli settings view
notescli attachment delete <ref> <attachment-id>
notescli link capture <ref> <url> [--title <title>] [--position <utf16-offset>]
notescli recording add <ref> --file <audio> [--transcribe | --transcript-file <json>] [--title <title>] [--locale <locale>]
notescli recording create --folder <folder> --title <title> --file <audio> [--transcribe | --transcript-file <json>] [--locale <locale>]
notescli recording transcribe-file --file <audio> --output <json> [--locale <locale>]
notescli recording transcribe <ref> [--attachment <id>] [--locale <locale>] [--transcript-file <json>]
notescli recording transcript <ref> [--format text|srt|vtt|json]
notescli recording clear-summary <ref> <attachment-id>
notescli drawing add <ref> --svg <file> [--ink pen|marker|pencil|monoline]
                [--width <width>] [--color <hex>] [--bw] [--size <width>x<height>]
                [--fit contain|stretch] [--fill outline|hatch]
notescli drawing create --folder <folder> --title <title> --svg <file> [drawing options]
notescli drawing export <ref> [--attachment <id>] [--format svg|png] [--output <file>]
notescli handwriting recognize <ref> --attachment <id> [--locale <locale>] [--persist]
notescli handwriting set <ref> --attachment <id> [--text <text> | --clear]
notescli paper add <ref> <pdf-or-image> [--subtype pdf|scan] [--position <position>]
notescli paper regenerate-fallback <ref> --attachment <id>
notescli table create|set|format-cell|add-row|add-column|remove-row|remove-column|convert-to-text ...
notescli duplicate <ref> [--title <title>]
notescli restore <ref> [--folder <folder>]
notescli write <ref> [--body <body> | --stdin | --file <file>] [--backup]
```

`link add-url --card` creates a native URL preview. `link capture` creates the native Synapse web attachment used for Share-sheet links. File and pasteboard attachments are copied to private temporary storage, hashed, and checked against the stored media. `map add` accepts only Apple Maps HTTPS URLs. Scan commands create and edit ordered native scan galleries; crop still lacks visible Mac/iPhone/PDF proof. Local scans accept up to 200 MB. MCP `scan_add` accepts up to 3 MB of decoded image data so requests fit the 4 MiB transport limit. Recording input is converted to M4A with AVFoundation. `recording transcribe-file` writes timed JSON without opening Notes. `--transcript-file` imports that JSON into a native Notes transcript; each segment's `fragment` index picks the audio fragment it belongs to, and 0 is the default. `recording transcribe` transcribes each fragment of a recording in order. Readback checks each segment's text, timing, speaker, and fragment. On-device transcription stays on the Mac. Drawing commands convert SVG paths and shapes to editable `com.apple.paper` PencilKit strokes. PNG export requires `--output`; SVG prints to standard output when no output path is set. Writes use the native engine by default. Commands without a native implementation fall back to scripting, and `--engine scripting` selects scripting explicitly. Write results include `engine` and `operationID`.

Settings commands read and write Notes' container preference files and verify the stored value. `settings view` reads the list or gallery mode Notes last saved for its main window; it cannot change it.

## Import

In the Notes CLI app, open **Import**, drop files or folders, choose a destination, and preview before writing. Use **Selected note** to add original files below a note's title.

```sh
notescli import --dry-run --json --folder "Careers > Systems" --mode combined -- ~/Desktop/guide.html ~/Desktop/guide.pdf
notescli import --json --folder "Careers > Systems" --mode combined --expect-plan "$import_token" --wait-sync -- ~/Desktop/guide.html ~/Desktop/guide.pdf
notescli import --dry-run --json --folder "Careers > Systems" --into '#7356' -- ~/Desktop/guide.pdf
```

Set `import_token` to the preview's `token`. The token prevents writing a changed plan. Use `--mode separate` for one note per file. If a previous import is unchanged, its exact repeat is skipped; possible overlaps require preview and do not replace existing notes. HTML imports are static; remote images stay links. Folder imports skip hidden files, symlinks, and app packages. Attachments can be up to 512 MB each, subject to Notes and iCloud limits. A verified local write is not proof of iCloud sync.

## Diagrams

```text
notescli diagram add <note> --file <diagram.svg|diagram.html|diagram.mmd>
        [--as image|drawing] [--width <pixels>] [--scale 2|3]
        [--background white|transparent|auto] [--dark]
notescli diagram create --folder <folder> --title <title> --file <diagram.svg|diagram.html|diagram.mmd>
        [--as image|drawing] [--width <pixels>] [--scale 2|3]
        [--background white|transparent|auto] [--dark]
notescli diagram export <note> --output <file> [--attachment-id <id>]
```

Image mode is the default. SVG and HTML render without JavaScript or access to local files or the network. Mermaid needs the official Mermaid 12.3.0 `mermaid.min.js` at `~/Library/Application Support/NotesCLI/mermaid.min.js`. Notes CLI checks its hash and runs it in isolation; the installer does not include it. The PNG contains the original SVG, HTML, or Mermaid source. Use `diagram export` to recover it, and pass `--attachment-id` when a note has more than one diagram.

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
Snapshots with native-only features use the native engine. Pass `--allow-downgrade` with `--engine scripting` to permit scripting conversion. Native restore recreates missing scans and markup, recordings and fragments, Paper documents, multi-canvas System Paper, modern and classic drawings, rich links, maps, tables, table-cell inline objects, paragraph links, PDFs, images, and files, including types without a canonical extension. It preserves paragraph and checklist UUIDs, restores private payloads, remaps attachment IDs, and verifies structure and archived bytes through fresh native and database reads. Paper verification compares the drawing assets and their semantic contents because Notes rewrites its CRDT and database bytes. A failed Paper restore purges only the newly created files when the guard proves ownership, but still reports an `unknown` result. Unknown future attachment graphs are refused.

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
notescli onboard
notescli permissions
notescli doctor
notescli engine doctor
notescli capabilities
notescli host install|status|restart|uninstall
notescli uninstall [--dry-run] [--keep-config]
notescli completion [zsh|bash|fish]
notescli editor [--help]
notescli editor --save-settings [<editor options>]
notescli editor --show-settings
notescli editor --check-for-updates
notescli editor --login enable|disable|status
notescli editor --open-accessibility | --export-logs
```

`setup` connects supported MCP clients and opens permission settings. `permissions` opens Full Disk Access and requests Notes Automation and Speech Recognition access.

`editor` adds a selection toolbar, slash commands, Markdown shortcuts, and ⌘P search to Apple Notes. Matches in note text show a short excerpt with the matching words in bold. Use … on the selection toolbar to hide, reorder, or restore buttons. A plain `editor` launch saves these changes; a launch with options keeps them for that run. The bottom-right bar offers Copy Markdown, Copy Note Link, and Backlinks without a text selection. Hide it with `--no-note-actions-bar`. Use `--menu-bar-icon` to add Search, Check for Updates, and Quit to the menu bar. Use `--automatic-update-checks` to check GitHub at startup and daily without installing anything. Both options are off by default. The editor runs until you press Control-C and needs Accessibility access for the on-screen controls. `editor --save-settings --no-markdown-shortcuts` saves that choice for the next plain `editor` launch. Passing options without `--save-settings` uses them for one run, starting from defaults. To reset, run `editor --save-settings` without options.

After `notescli onboard`, run `notescli editor --login enable` to start the editor in the background with your saved settings. This is off by default. If macOS denies access, run `notescli editor --open-accessibility`, allow Notes CLI, then run `--login enable` again. `--login disable` stops the login job without stopping the Notes CLI permission helper.

## MCP

```text
notescli mcp [--allow-native]
notescli mcp install [--client claude-code|claude-desktop|codex|cursor|vscode|tailscale|all] [--read-only] [--allow-native] [--write-folders FOLDERS]
notescli mcp uninstall [--client claude-code|claude-desktop|codex|cursor|vscode|tailscale|all]
notescli mcp status [--client claude-code|claude-desktop|codex|cursor|vscode|tailscale|all]
notescli mcp token show|rotate
```

Running `notescli mcp` with no subcommand starts the stdio server. Native tools are available by default on write-enabled servers. `--allow-native` remains accepted for older configurations. Client selection defaults to `all`.
