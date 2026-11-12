# Connect NotesCLI to MCP clients

NotesCLI runs a stdio MCP server:

```bash
notescli mcp
```

The default server exposes 49 tools. Read-only mode exposes 26 read tools. `notescli mcp --allow-native` exposes 91 tools in total.

## Tools

Read tools:

```text
list_accounts  list_folders  list_notes  search_notes  query_notes
get_note  get_notes  list_tags  list_attachments  list_backlinks
get_deeplink  list_smart_folders  list_deleted  recent_notes  today_notes
count_notes  get_stats  get_raw_note  related_notes  get_write_policy  file_diff
index_status  get_attachment  anchor_list  anchor_resolve  table_get
```

Scripting, export, and sync tools:

```text
save_attachment  export_notes  file_pull  file_push  sync_notes  anchor_add
anchor_prune
create_note  append_to_note  prepend_to_note  update_note
insert_under_heading  replace_section  replace_text  rename_note
move_note  delete_note  batch_move_notes  batch_delete_notes
create_folder  rename_folder  delete_folder  write_markdown
```

`export_notes` accepts `markdown`, `html`, `json`, `ndjson`, `sqlite`, `zip`, `pdf`, `docx`, `rtf`, `epub`, `bear`, `joplin`, and `quiver`. It also accepts `combine`, `scans_pdf`, and `order` (`display`, `modified`, `created`, or `title`).

`file_pull` and `file_push` accept `dry_run`. `file_diff` reads the local sidecar merge base and does not write.

Tools added by `--allow-native`:

```text
checklist_list  checklist_add  checklist_toggle  checklist_check_all
checklist_uncheck_all  checklist_clear_done  pin_note  unpin_note
tag_add  tag_remove  tag_rename  tag_delete  link_add  link_list
attach_pasteboard  add_url
smart_folder_create  smart_folder_rename  smart_folder_delete
text_find  text_insert  text_delete  text_replace
format_paragraph  format_inline  attach_file  delete_attachment
table_create  table_set  table_add_row  table_add_column
table_remove_row  table_remove_column  duplicate_note  restore_note  move_folder
```

The server also provides `notes://folders`, the `notes://note/{uuid}` resource template, and the `find_note` and `weekly_review` prompts. Note references accept UUIDs, Core Data IDs, short IDs such as `n123`, bare numeric IDs such as `123`, and unambiguous titles.

`list_notes`, `search_notes`, and `query_notes` return an opaque `next_cursor` made from the sort key and note ID. Pass it back as `cursor`. Body reads still use `offset` and `limit`. Responses stay within the 48 KB budget.

`get_note` accepts `format=outline` and returns a heading tree with UTF-16 offsets. `list_notes` and `search_notes` accept `has` with `image`, `audio`, `pdf`, `scan`, `drawing`, `table`, `checklist`, `link`, or `file`. `list_accounts` includes `default_location`.

`get_attachment` returns resized PNG/JPEG image blocks up to 1600 pixels and inline audio blocks when they fit. Larger files return a resource link. `table_get` returns decoded native tables as Markdown, JSON, or CSV. The anchor tools use `~/Library/Application Support/NotesCLI/anchors.sqlite`. `index_status` returns index details and background-job progress.

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

Every Notes write uses the folder allowlist, concurrency checks, journal, snapshots, and fresh readback. Pass `write_folders` per call or set `NOTESCLI_WRITE_FOLDERS` for the server. Read-only mode hides filesystem write tools as well as Notes write tools.

Native tools stay hidden unless the server starts with `--allow-native`. Native write results include `engine` and `operationID` when available. They write through Notes' private framework and persistent data store and can break after a macOS update.

`create_note` accepts an `attachments` array in native mode. With native mode enabled, `update_note` and `write_markdown` preserve `notescli-attachment:ID` references. Write tools accept `allow_shared`, `wait_sync`, and `sync_timeout`. Shared writes require Notes write permission. A sync timeout returns `syncPending: true` without retrying the write.

## Troubleshoot

Run:

```bash
notescli doctor --json
notescli mcp status
notescli permissions
```

If a desktop client cannot start the server, reinstall its entry from the final installed binary. If reads fail, grant Full Disk Access to the app that hosts MCP. If writes fail, allow that app to automate Notes.
