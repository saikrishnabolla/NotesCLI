# Connect NotesCLI to MCP clients

NotesCLI runs a stdio MCP server:

```bash
notescli mcp
```

## Install client config

```bash
notescli mcp install --client all
notescli mcp status
```

Use `--read-only` to hide every write tool:

```bash
notescli mcp install --client codex --read-only
```

The installer records the absolute path of the running `notescli` binary. It updates only the `notescli` server entry and preserves other servers. Before changing an existing file, it writes a timestamped `.backup-*` copy.

| Client | Config method |
| --- | --- |
| Claude Code | `claude mcp add --scope user` when the `claude` command exists |
| Claude Desktop | `~/Library/Application Support/Claude/claude_desktop_config.json` |
| Codex | `~/.codex/config.toml` under `[mcp_servers.notescli]` |
| Cursor | `~/.cursor/mcp.json` |
| VS Code | `~/Library/Application Support/Code/User/mcp.json` |

Restart desktop clients after changing their config.

## Remove client config

```bash
notescli mcp uninstall --client cursor
notescli mcp uninstall --client all
```

Removal deletes only the `notescli` entry and backs up a file before changing it.

## Use the plugins

The repository includes a Claude Code marketplace in `.claude-plugin/marketplace.json` and a Codex marketplace in `.agents/plugins/marketplace.json`. Both start the installed `notescli mcp` server and include the NotesCLI agent skill.

## Write safety

Every MCP write tool accepts `dry_run: true`. A real write returns an `outcome`:

- `verified`: a fresh database snapshot found the change.
- `unverified`: Notes accepted the write, but the readback did not prove it.
- `unknown`: the request timed out or lost its response. Read current state and never retry automatically.

Use a folder named `notescli-test` and titles beginning with `notescli-test-` for agent experiments. Delete moves items to Recently Deleted.

## Troubleshoot

Run:

```bash
notescli doctor --json
notescli mcp status
notescli permissions
```

If a desktop client cannot start the server, reinstall its entry from the final installed binary. If reads fail, grant Full Disk Access to the app that hosts MCP. If writes fail, allow that app to automate Notes.
