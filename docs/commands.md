# Command reference

This reference follows `notescli --help` from version 1.0.0.

## Global options

```text
--backend <backend>  Backend: default or fake. Also accepts NOTESCLI_BACKEND.
--engine <engine>    Write engine: scripting or native. Also accepts NOTESCLI_ENGINE.
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
              [--limit <limit>] [--sort modified|created|opened|title|display]
              [--include-deleted]
notescli show <ref> [--format markdown|text|html|json] [--no-attachments]
notescli show-many <refs> ... [--format markdown|text|html|json]
notescli search <query> [--folder <folder>] [--limit <limit>]
                [--fuzzy | --index] [--rebuild]
notescli tags
notescli recent [<n>]
notescli fetch <ref> | --all [--wait <seconds>]
notescli index [--rebuild] [--status]
notescli stats
notescli count [--folder <folder>] [--account <account>] [--include-deleted]
notescli selection
notescli deeplink <ref>
notescli backlinks <ref>
notescli attachments <ref> [--save <directory>]
notescli raw <ref>
notescli deleted
notescli smart-folders [--evaluate]
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
notescli prepend <ref> [--body <body> | --stdin]
notescli insert-under-heading <ref> <heading> [--body <body> | --stdin]
notescli replace-section <ref> <heading> [--body <body> | --stdin]
notescli replace-text <ref> <find> <replacement>
notescli clip <url> [--folder <folder>]
```

`add` opens `$EDITOR` when no body source is given. `edit` replaces the note body and may reduce rich Notes content to the supported Markdown subset. `delete` moves notes to Recently Deleted.

## Folder writes

```text
notescli folder create <name> [--parent <parent>] [--account <account>]
notescli folder rename <ref> <name>
notescli folder move <ref> [<parent>] [--account <account>]
notescli folder delete <ref> [--yes] [--expect-count <count>]
notescli folder exists <path>
```

Deleting a folder moves its notes to Recently Deleted.

## Rich writes

These commands require `--engine native` unless a scripting path is listed:

```text
notescli checklist add|toggle|check-all|uncheck-all|clear-done|list ...
notescli pin <ref>
notescli unpin <ref>
notescli tag add|remove|rename|delete ...
notescli link add|list ...
notescli text insert|delete|replace|find ...
notescli format paragraph|inline ...
notescli attach <ref> <path> [--position <position>] [--view <view>]
notescli attachment delete <ref> <attachment-id>
notescli table create|set|add-row|add-column|remove-row|remove-column ...
notescli duplicate <ref> [--title <title>]
notescli restore <ref> [--folder <folder>]
notescli write <ref> [--body <body> | --stdin | --file <file>] [--backup]
```

`write` uses scripting by default. Restore and folder moves require native opt-in. Write results include the selected `engine`; native results include `operationID` when available.

All write commands accept `--dry-run`, `--idempotency-key`, `--write-folders`, `--if-modified`, and `--expect-revision`. Body rewrites also accept `--allow-attachment-loss`.

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
notescli completion [zsh|bash|fish]
```

`setup` connects supported MCP clients and opens permission settings. `permissions` opens Full Disk Access and requests Notes Automation access.

## MCP

```text
notescli mcp [--allow-native]
notescli mcp install [--client claude-code|claude-desktop|codex|cursor|vscode|all] [--read-only]
notescli mcp uninstall [--client claude-code|claude-desktop|codex|cursor|vscode|all]
notescli mcp status [--client claude-code|claude-desktop|codex|cursor|vscode|all]
```

Running `notescli mcp` with no subcommand starts the stdio server. Client selection defaults to `all`.
