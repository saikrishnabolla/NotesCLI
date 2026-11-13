# Changelog

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
