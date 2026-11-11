# NotesCLI

NotesCLI is a native macOS command and MCP server for Apple Notes. It reads a private copy of the Notes database and sends writes through Notes.app. It never writes to the database.

You need macOS 14 or later. Reading Notes requires Full Disk Access. Creating or changing notes requires Automation access to Notes.

## Install

With Homebrew:

```bash
brew install --formula https://raw.githubusercontent.com/saikrishnabolla/NotesCLI/main/packaging/homebrew/notescli.rb
notescli setup
```

From a release archive:

```bash
tar -xzf notescli-1.0.0-macos-universal.tar.gz
install -m 755 notescli "$HOME/.local/bin/notescli"
notescli setup
```

To build from source:

```bash
git clone https://github.com/saikrishnabolla/NotesCLI.git
cd NotesCLI
swift build -c release
install -m 755 .build/release/notescli "$HOME/.local/bin/notescli"
notescli setup
```

See [Installation](docs/install.md) for permissions and Gatekeeper notes.

## Permissions

Run:

```bash
notescli permissions
notescli doctor
```

`notescli permissions` opens the Full Disk Access pane and makes a harmless Apple Event request to Notes. Grant access to the app that starts NotesCLI: your terminal for shell use, or Claude, Codex, Cursor, or VS Code for MCP use.

## Common commands

```bash
notescli accounts --json
notescli folders --tree
notescli list --limit 20 --json
notescli search "project plan" --json
notescli show NOTE_ID --format markdown
notescli recent 10 --json
notescli add "Meeting notes" --body "# Notes"
notescli append NOTE_ID --body "Follow up Friday"
notescli export --out notes-export --attachments
notescli delete NOTE_ID --yes
```

Writes return `verified`, `unverified`, or `unknown`. If a write returns `unknown`, check the note before you retry. Delete moves notes to Recently Deleted.

See [Commands](docs/commands.md) for the full command list.

## MCP setup

Connect every supported client:

```bash
notescli mcp install --client all
notescli mcp status
```

Start with read-only tools:

```bash
notescli mcp install --client all --read-only
```

Supported clients are Claude Code, Claude Desktop, Codex, Cursor, and VS Code. Existing config files are backed up before a change. See [MCP setup](docs/mcp.md) for paths, removal, and plugin installation.

## How it compares

| Tool | Strength | Tradeoff |
| --- | --- | --- |
| NotesCLI | Native universal binary, JSON CLI, MCP, database snapshots, and checked AppleScript writes | Smaller feature set than the largest private-framework tools |
| memo | Fast terminal workflow with `fzf` and previews | No MCP server; depends on Python and terminal helpers |
| notekit | Broad rich-note editing and Markdown sync | Uses private Notes frameworks and has no MCP server |
| apple-notes-mcp by sweetrb | Large MCP tool set for rich objects, attachments, and diagnostics | Node-based and uses a mix of database, scripting, and helper paths |
| macnotesapp | Mature Python CLI with exports, selection access, and attachments | No built-in MCP server |
| apple-mcp by xiaofeng-han | Broad CLI, MCP, agent setup, and rich native objects | Relies on private Apple frameworks that may change with macOS |

NotesCLI favors a small install, structured output, database read safety, and explicit write outcomes. Notekit, sweetrb's server, and xiaofeng-han's tool cover more rich-object editing and sync features.

## License

MIT. See [LICENSE](LICENSE).
