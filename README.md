# NotesCLI

NotesCLI is a macOS command and MCP server for Apple Notes. It reads a private copy of the Notes database. By default, it sends writes through Notes.app scripting.

You need macOS 14 or later. Reading Notes requires Full Disk Access. Creating or changing notes requires Automation access to Notes.

## Install

With Homebrew:

```bash
brew install saikrishnabolla/notescli/notescli
notescli setup
```

From a release archive:

```bash
tar -xzf notescli-1.0.1-macos-universal.tar.gz
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

Run `notescli` in a terminal for the command home screen and five recently edited notes. Scripts and agents should pass `--json`.

```bash
notescli accounts --json
notescli folders --tree
notescli list --limit 20 --json
notescli search "project plan" --json
notescli show '#8800' --format markdown
notescli recent 10 --json
notescli pinned --limit 20
notescli capabilities --json
notescli add "Meeting notes" --body "# Notes"
notescli append NOTE_ID --body "Follow up Friday"
notescli diagram add NOTE_ID --file system-flow.html
notescli checklist add NOTE_ID "Follow up Friday" --engine native
notescli export --out notes-export --attachments
notescli delete NOTE_ID --yes
```

Writes return `verified`, `unverified`, `unknown`, or `rolled_back`, plus the `engine` used. `rolled_back` means a native create failed and its partial note was moved to Recently Deleted. Native results also include `operationID` when available. If a write returns `unknown`, check the note before you retry. Delete moves notes to Recently Deleted.

Rich edits such as native checklists, pins, tags, links, highlights, positioned images, tables, table-cell formatting, paragraph styles, range edits, duplication, restore, and folder moves require `--engine native` or `NOTESCLI_ENGINE=native`. Native undo and revert verify the note ID and title, decoded text and runs, tables and rich cells, and attachment IDs, types, and parent relationships through a fresh database read. They do not compare attachment file bytes. The scripting engine refuses these snapshots unless you pass `--allow-downgrade`. See the [Apple Notes feature inventory](docs/APPLE-NOTES-FEATURES.md) for all 95 rows.

`diagram add` renders self-contained SVG or HTML through WebKit, crops it, and inserts a 2x or 3x PNG. The PNG stores the original source for `diagram export`. See the bundled `notescli-diagrams` skill for the agent workflow.

The native engine uses Apple's private Notes framework and writes through Notes' own persistent data store. It is opt-in because Apple can change this framework in a macOS update. Keep a backup and run `notescli engine doctor` before using it.

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

The repository includes an agent skill at [`skills/notescli/SKILL.md`](skills/notescli/SKILL.md). `notescli mcp install` points to it after installing the server entry.

## How it compares

| Tool | Strength | Tradeoff |
| --- | --- | --- |
| NotesCLI | Universal binary, JSON CLI, MCP, snapshots, checked scripting writes, and opt-in rich native edits | Native edits use a private Apple framework that can change with macOS |
| memo | Fast terminal workflow with `fzf` and previews | No MCP server; depends on Python and terminal helpers |
| notekit | Broad rich-note editing and Markdown sync | Uses private Notes frameworks and has no MCP server |
| apple-notes-mcp by sweetrb | Large MCP tool set for rich objects, attachments, and diagnostics | Node-based and uses a mix of database, scripting, and helper paths |
| macnotesapp | Mature Python CLI with exports, selection access, and attachments | No built-in MCP server |
| apple-mcp by xiaofeng-han | Broad CLI, MCP, agent setup, and rich native objects | Relies on private Apple frameworks that may change with macOS |

NotesCLI keeps scripting as the default write path and reports explicit write outcomes. Rich native writes require an explicit opt-in.

## License

MIT. See [LICENSE](LICENSE).
