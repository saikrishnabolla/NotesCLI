# Changelog

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
