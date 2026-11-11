# Command reference

This reference follows `notescli --help` from version 1.0.0.

## Global options

```text
--backend <backend>  Backend: default or fake. Also accepts NOTESCLI_BACKEND.
--read-only          Refuse all writes.
--json               Print JSON, including errors on stderr.
--version            Show the version.
-h, --help           Show help information.
```

Use `--json` for scripts and agents. A note reference can be a UUID, Core Data ID, or an unambiguous title.

## Read commands

```text
notescli accounts
notescli folders [--account <account>] [--tree]
notescli list [--folder <folder>] [--account <account>] [--pinned]
              [--tag <tag>] [--since <since>] [--until <until>]
              [--limit <limit>] [--include-deleted]
notescli show <ref> [--format markdown|text|html|json] [--no-attachments]
notescli search <query> [--folder <folder>] [--limit <limit>] [--fuzzy]
notescli tags
notescli recent [<n>]
notescli open <ref>
```

`recent` defaults to 10 notes. `list` excludes Recently Deleted unless you pass `--include-deleted`.

## Note writes

```text
notescli add [<title>] [--folder <folder>] [--body <body> | --stdin | --file <file>]
notescli append <ref> [--body <body> | --stdin]
notescli edit <ref>
notescli rename <ref> <title>
notescli move <ref> <folder>
notescli delete <refs> ... [--yes]
```

`add` opens `$EDITOR` when no body source is given. `edit` replaces the note body and may reduce rich Notes content to the supported Markdown subset. `delete` moves notes to Recently Deleted.

## Folder writes

```text
notescli folder create <name> [--parent <parent>] [--account <account>]
notescli folder rename <ref> <name>
notescli folder delete <ref> [--yes]
```

Deleting a folder moves its notes to Recently Deleted.

## Export

```text
notescli export [--out <out>] [--folder <folder>]
                [--format markdown|html|json] [--attachments]
```

The default output directory is `notes-export`. Export reads Notes and writes local files.

## Setup and diagnostics

```text
notescli setup
notescli permissions
notescli doctor
notescli completion [zsh|bash|fish]
```

`setup` connects supported MCP clients and opens permission settings. `permissions` opens Full Disk Access and requests Notes Automation access.

## MCP

```text
notescli mcp
notescli mcp install [--client claude-code|claude-desktop|codex|cursor|vscode|all] [--read-only]
notescli mcp uninstall [--client claude-code|claude-desktop|codex|cursor|vscode|all]
notescli mcp status [--client claude-code|claude-desktop|codex|cursor|vscode|all]
```

Running `notescli mcp` with no subcommand starts the stdio server. Client selection defaults to `all`.
