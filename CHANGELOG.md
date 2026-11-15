# Changelog

## 1.1.11

### Fixed

- Settings writes now stop if the value changes after NotesCLI captures the undo preimage.

## 1.1.10

### Added

- Native OCR and image-label writes support exact readback, history, and undo.
- Attachment markup can be inspected, copied, set, cleared, exported, and restored with structural and stored-payload readback. Editability after reopening Notes remains unverified.
- Scanned documents support edge detection and perspective correction.
- NotesCLI can read Notes' last-saved list or gallery mode and change sorting, note counts, dark backgrounds, zoom, and Quick Note behavior.
- Recording-summary metadata can be removed and restored through history. No Apple-generated summary fixture was available for live verification.

### Fixed

- Snapshot restore preserves existing scan state, editable markup, recording metadata, and deleted-note locations.
- Scan restore checks revisions before any scan editor saves and reports interrupted saved writes as unsafe to retry.
- Notes move operations now have a timeout and report delayed writes as unsafe to retry.
- MCP journals no longer retain caller-supplied scan page paths.

## 1.1.9

### Added

- Password-backed V1 Neo reads can decrypt cipher-3 sidecar attachments with Apple's stored sidecar key or verified main-key fallback. This follows Apple's format and passes Apple-generated fixtures; no real cipher-3 note exists on this Mac.
- `collaboration activity` and MCP `collaboration_activity` export stored collaboration events as bounded raw data and hashes without changing Notes.
- Handwriting recognition results can be saved, replaced, and cleared with native and database readback.

### Fixed

- Native MCP note and paragraph links no longer deadlock during post-write verification.
- Release archives can be built from a clean checkout. Manual GitHub releases now require Developer ID signing and notarization credentials.

## 1.1.8

### Fixed

- Fake and dry-run native commands no longer depend on private Notes selectors from the current macOS version.
- Missing scan-edit selectors now disable only the affected scan operation instead of the whole native engine.

## 1.1.7

### Added

- History, undo, and revert can recreate scans and markup, recordings, Paper documents, modern and classic drawings, rich links, maps, tables, paragraph links, inline objects, and generic files.
- Native note links can target a paragraph, and history preserves paragraph and checklist identities.
- Password-supplied reads support V1 and V1 Neo locked-note bodies and attachments.

### Changed

- Snapshot restoration now checks object structure, private payloads, and archived media through fresh native and database reads.
- Body replacement uses Notes' atomic range operation, and changed bodies are checked before Core Data saves them.
- Automatic routing skips an outdated capability host. Forced routing explains how to update it with `notescli onboard`.

## 1.1.6

### Fixed

- `mcp uninstall --client all` now removes only MCP client integrations. The capability host and other NotesCLI files remain until `notescli uninstall` is run.

## 1.1.5

### Fixed

- Local and Tailscale MCP keep the main run loop available so native Notes calls cannot deadlock while opening Apple's shared Notes context.
- MCP diagram writes render on the main run loop, including SVG files that define only a `viewBox`.

## 1.1.4

### Fixed

- MCP `create_note` honors `engine: "native"` without attachments and rejects unsupported native requests instead of using the scripting engine.
- Full-body writes ignore Apple Notes' built-in title metadata while still protecting custom fonts, sizes, and right-to-left text.
- The fake backend stays local when the capability host is installed.
- Protected-folder discovery skips locale folders that do not contain a strings file.

## 1.1.3

### Fixed

- Long-running MCP servers now refresh their Notes snapshot when the database changes, so a note can be read or changed immediately after creation.

## 1.1.2

### Fixed

- `notescli permissions` now requests and verifies Notes Automation access for the signed capability host instead of reporting a false success from `osascript`.

## 1.1.1

### Security

- A Tailscale MCP server can set a hard write-folder ceiling that remote calls may narrow but cannot broaden. Malformed limits fail closed, and restores check their destination folder.

## 1.1.0

### Added

- A signed capability host keeps Full Disk Access, Automation, and Speech Recognition permissions in one app.
- `notescli mcp install --client tailscale` publishes an authenticated HTTPS MCP endpoint on the tailnet.
- Reads fall back to Notes Automation when Full Disk Access is missing and report `fidelity: "limited"`.
- `doctor --for-agent --json`, resumable `onboard`, token rotation, and manifest-based uninstall.
- MCP 2026-07-28, parallel reads, cancellation, and an MCP Apps result widget.

### Security

- The HTTP server binds to loopback, checks bearer tokens before reading request bodies, restricts hosts and origins, and caps requests at 4 MiB.
- The capability host checks the caller and bundled CLI signatures, blocks path-bearing commands, and stops child processes when clients disconnect.

## 1.0.3

### Fixed

- On-device transcription no longer crashes when notescli runs from Terminal or an MCP host. macOS checked the launching app for a Speech Recognition usage description and killed notescli. Speech Recognition now runs in a helper process that macOS treats as notescli itself.

## 1.0.2

### Fixed

- `drawing export --format png` keeps stored ink colors when the Mac is in dark mode. Black strokes were exported as light gray.

## 1.0.1

### Fixed

- On macOS 26, a missing divider selector no longer disables every native feature. Only dividers are unavailable, and `capabilities` says so.
- The release zip contains only the `notescli` binary.

## 1.0.0

### Added

- Apple Notes reads from a private snapshot of `NoteStore.sqlite`.
- Notes and folder writes through Notes.app, with post-write checks.
- JSON output, Markdown export, and a stdio MCP server.
- MCP setup for Claude Code, Claude Desktop, Codex, Cursor, and VS Code.
- Universal signed release archives, Homebrew packaging, and release CI.
