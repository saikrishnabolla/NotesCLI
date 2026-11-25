# Notes CLI

Notes CLI is a macOS command and MCP server for Apple Notes. It reads a private copy of the Notes database. It uses the native Notes engine for supported writes and Notes.app scripting for the rest.

You need macOS 14 or later. Full-fidelity reads require Full Disk Access. Without it, accounts, folders, lists, search, and note text use a limited Notes Automation reader. Creating or changing notes requires Automation access to Notes.

## Install

With Homebrew:

```bash
brew install saikrishnabolla/notescli/notescli
notescli onboard
```

From a release archive:

```bash
tar -xzf notescli-1.1.16-macos-universal.tar.gz
mkdir -p "$HOME/.local/bin" "$HOME/Applications"
install -m 755 notescli "$HOME/.local/bin/notescli"
ditto "Notes CLI.app" "$HOME/Applications/Notes CLI.app"
"$HOME/.local/bin/notescli" onboard
```

To build from source:

```bash
git clone https://github.com/saikrishnabolla/NotesCLI.git
cd NotesCLI
swift build -c release
install -m 755 .build/release/notescli "$HOME/.local/bin/notescli"
notescli onboard
```

See [Installation](docs/install.md) for permissions and Gatekeeper notes.

## First run

Run `notescli onboard` after an install or upgrade. It installs or updates `~/Applications/Notes CLI.app`, starts it, and resumes where you left off until required access is ready.

```bash
notescli onboard
```

Grant Full Disk Access to **Notes CLI** in System Settings. The helper runs in the background with no window or menu bar item. Grant Automation, Camera, or Speech Recognition only when you need those features.

Commands that open or save local files run in the calling app so the host never receives arbitrary paths. Those commands need that app's own file access.

For a formatting bar, typing shortcuts, and quick search inside Apple Notes, run `notescli editor --help`.

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
notescli checklist add NOTE_ID "Follow up Friday"
notescli export --out notes-export --attachments
notescli delete NOTE_ID --yes
```

Writes return `verified`, `unverified`, `unknown`, or `rolled_back`, plus the `engine` used. `rolled_back` means a native create failed and its partial note was moved to Recently Deleted. Native results also include `operationID` when available. If a write returns `unknown`, check the note before you retry. Delete moves notes to Recently Deleted.

Rich edits such as native checklists, pins, tags, links, highlights, positioned images, maps, scanned documents, tables, table-cell formatting, paragraph styles, range edits, duplication, restore, folder grouping, default style, and folder moves use the native engine by default. Pass `--engine scripting` or set `NOTESCLI_ENGINE=scripting` when you need the scripting path. Native undo and revert verify the title, pin state, decoded text and runs, paragraph and checklist identities, tables and rich cells, attachment topology, private link payloads, and archived media through fresh native and database reads. They recreate missing scans and markup, recordings and fragments, Paper documents, multi-canvas System Paper, modern and classic drawings, rich links, maps, tables, table-cell inline objects, paragraph links, PDFs, images, and files. Explicit native UTI creation also preserves file types that have no canonical extension. Unknown future attachment graphs are refused. The scripting engine refuses native-only snapshots unless you pass `--allow-downgrade`. See the [Apple Notes feature inventory](docs/APPLE-NOTES-FEATURES.md) for all 95 rows.

`show --password-stdin --no-attachments` reads V1 and V1 Neo Notes-password-locked bodies. `attachments --password-stdin --save <directory>` exports their decrypted attachments, including V1 Neo cipher-3 sidecars. Cipher-3 support follows Apple's format and passes Apple-generated fixtures; no real cipher-3 note exists on this Mac. Device-key/passcode V2 protection remains unsupported. Notes CLI never stores the password.

`diagram add` renders self-contained SVG or HTML through WebKit, crops it, and inserts a 2x or 3x PNG. The PNG stores the original source for `diagram export`. See the bundled `notescli-diagrams` skill for the agent workflow.

The native engine uses Apple's private Notes framework and writes through Notes' own persistent data store. Apple can change this framework in a macOS update. Keep a backup and run `notescli engine doctor` after macOS updates.

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

Publish MCP on this Mac's tailnet:

```bash
notescli mcp install --client tailscale
notescli mcp token show
```

The repository includes an agent skill at [`skills/notescli/SKILL.md`](skills/notescli/SKILL.md). `notescli mcp install` points to it after installing the server entry.

## How it compares

| Tool | Strength | Tradeoff |
| --- | --- | --- |
| Notes CLI | Universal binary, JSON CLI, MCP, snapshots, native rich edits, and checked scripting fallback | Native edits use a private Apple framework that can change with macOS |
| memo | Fast terminal workflow with `fzf` and previews | No MCP server; depends on Python and terminal helpers |
| notekit | Broad rich-note editing and Markdown sync | Uses private Notes frameworks and has no MCP server |
| apple-notes-mcp by sweetrb | Large MCP tool set for rich objects, attachments, and diagnostics | Node-based and uses a mix of database, scripting, and helper paths |
| macnotesapp | Mature Python CLI with exports, selection access, and attachments | No built-in MCP server |
| apple-mcp by xiaofeng-han | Broad CLI, MCP, agent setup, and rich native objects | Relies on private Apple frameworks that may change with macOS |

Notes CLI uses native writing by default, falls back to scripting where needed, and reports explicit write outcomes.

## License

MIT. See [LICENSE](LICENSE).
