# Apple Notes tool parity

## 1. Capability matrix

Inspected 38 repositories on 2026-11-11: the 17 requested projects plus 21 found through GitHub repository/issue searches for Apple Notes CLI, MCP, export and sync. This is a source audit at the linked commits, not a runtime compatibility test or a claim to cover every repository on GitHub. No personal Notes data was accessed. “Have it” means implemented in the inspected source; limits and README mismatches are called out below. Tool names link to source files; section 2 links each README and command registry.

Additional projects with public usage reports include [sirmews (#5)](https://github.com/sirmews/apple-notes-mcp/issues/5), [ailenshen (#6)](https://github.com/ailenshen/apple-notes-mcp/issues/6), [Dan8Oren (#19)](https://github.com/Dan8Oren/mcp-apple-notes/issues/19), [disco-trooper (#8)](https://github.com/disco-trooper/apple-notes-mcp/issues/8), [stash (#4)](https://github.com/shakedlokits/stash/issues/4), [macnotesapp (#86)](https://github.com/RhetTbull/macnotesapp/issues/86) and [storizzi (#31)](https://github.com/storizzi/notes-exporter/issues/31). Other additions broaden source coverage; public usage is not established for every project.

Phases: **1** read; **2** scripting write; **3** opt-in private-framework rich write; **4** MCP/agent; **5** sync/advanced. The status column records the current NotesCLI command or MCP tool and names any remaining gap. Baseline: [NotesReading/NotesWriting](../Sources/NotesCore/Backend.swift), [document model](../Sources/NotesCore/Document.swift), [models](../Sources/NotesCore/Model.swift). Combined cells describe a capability family; the limits column distinguishes implementations.

Status summary: 127 Done, 2 Partial, and 10 Not possible.

| Capability | Which tools have it (repo names) | How they do it | notescli phase | Notes (limits seen) | Status |
| --- | --- | --- | --- | --- | --- |
| List notes in a folder | [antoniorodr/memo][memo]; [johnmatthewtennant/notekit-cli][mk]; [JaviSoto/apple-notes-cli][javi]; [xwmx/notes-app-cli][xwmx]; [cardmagic/notes][card]; [sweetrb/apple-notes-mcp][sweet]; [danielhopkins/apple-tools][apple]; [mattjefferson/honeycrisp][honey]; [biao29/notesctl][biao]; [FradSer/note][frad]; [krasun/notes-mcp][kras]; [henilcalagiya/mcp-apple-notes][hen]; [RodriguesJohn/applenotesmcp][rod]; [Dan8Oren/mcp-apple-notes][dan]; [disco-trooper/apple-notes-mcp][disco]; [shareup/nanotes][nano]; [RhetTbull/macnotesapp][mac]; [RhetTbull/apple-notes-parser][rparser]; [mattt/iMCP][imcp]; [xiaofeng-han/apple-mcp][xiao]; [ailenshen/apple-notes-mcp][ail] | AppleScript/JXA or ScriptingBridge; DB/private reads | 1 | Folder IDs/paths avoid same-name collisions; title-only selectors differ by tool. | Done — `list`; `list_notes` |
| List accounts and set the default account | [JaviSoto/apple-notes-cli][javi]; [xwmx/notes-app-cli][xwmx]; [sweetrb/apple-notes-mcp][sweet]; [mattjefferson/honeycrisp][honey]; [RhetTbull/macnotesapp][mac]; [threeplanetssoftware/apple_cloud_notes_parser][parser]; [RhetTbull/apple-notes-parser][rparser] | AppleScript/ScriptingBridge; DB; private framework | 1 | macnotesapp routes IMAP accounts through Notes.app because they are absent from NoteStore.sqlite. [README.md][mac-38] | Done — `accounts`; `accounts --set-default`; `list_accounts`; `set_default_account` |
| List nested folder tree and counts | [sweetrb/apple-notes-mcp][sweet]; [JaviSoto/apple-notes-cli][javi]; [antoniorodr/memo][memo]; [henilcalagiya/mcp-apple-notes][hen]; [RhetTbull/macnotesapp][mac]; [threeplanetssoftware/apple_cloud_notes_parser][parser]; [RhetTbull/apple-notes-parser][rparser]; [xiaofeng-han/apple-mcp][xiao]; [ailenshen/apple-notes-mcp][ail] | AppleScript/JXA; DB/private framework | 1 | A flat folder name is insufficient to select an account + nested path. | Done — `folders --tree`; `list_folders` |
| List recently changed notes / today | [cardmagic/notes][card]; [sweetrb/apple-notes-mcp][sweet]; [shareup/nanotes][nano]; [xiaofeng-han/apple-mcp][xiao]; [ailenshen/apple-notes-mcp][ail]; [mattt/iMCP][imcp] | DB/private framework; JXA | 1 | nanotes accepts relative windows; sweetrb has an exact modification-time cursor. | Done — `recent`; `recent_notes`; `today_notes` |
| Filter created/modified dates, tags, pins, attachment kinds | [sweetrb/apple-notes-mcp][sweet]; [xiaofeng-han/apple-mcp][xiao]; [RhetTbull/apple-notes-parser][rparser]; [mattt/iMCP][imcp] | DB/private framework | 1 | Filter sets vary; sweetrb also has Quick Note, shared, word-count and checklist predicates. | Done — `list --has`; `search --has`; MCP `has` |
| Boolean query language | [sweetrb/apple-notes-mcp][sweet] | DB + decoded protobuf | 1 | AND/OR/NOT, parentheses and field predicates; scan cap 10,000, result cap 500. [src/utils/noteQuery.ts][sweet-39] | Done — `search --index`; `query_notes` |
| Title substring search | [antoniorodr/memo][memo]; [johnmatthewtennant/notekit-cli][mk]; [JaviSoto/apple-notes-cli][javi]; [cardmagic/notes][card]; [sweetrb/apple-notes-mcp][sweet]; [danielhopkins/apple-tools][apple]; [mattjefferson/honeycrisp][honey]; [biao29/notesctl][biao]; [FradSer/note][frad]; [RodriguesJohn/applenotesmcp][rod]; [Siddhant-K-code/mcp-apple-notes][sid]; [Dan8Oren/mcp-apple-notes][dan]; [disco-trooper/apple-notes-mcp][disco]; [shareup/nanotes][nano]; [RhetTbull/macnotesapp][mac]; [RhetTbull/apple-notes-parser][rparser]; [ailenshen/apple-notes-mcp][ail]; [xiaofeng-han/apple-mcp][xiao] | DB/private framework; AppleScript/JXA | 1 | memo fuzzy picker matches filenames/titles. JaviSoto --query and apple-tools search are title searches. | Done — `search`; `search_notes` |
| Body substring / full-text search | [johnmatthewtennant/notekit-cli][mk]; [cardmagic/notes][card]; [sweetrb/apple-notes-mcp][sweet]; [mattjefferson/honeycrisp][honey]; [biao29/notesctl][biao]; [FradSer/note][frad]; [henilcalagiya/mcp-apple-notes][hen]; [RodriguesJohn/applenotesmcp][rod]; [Dan8Oren/mcp-apple-notes][dan]; [disco-trooper/apple-notes-mcp][disco]; [RhetTbull/macnotesapp][mac]; [RhetTbull/apple-notes-parser][rparser]; [ailenshen/apple-notes-mcp][ail]; [xiaofeng-han/apple-mcp][xiao] | Decoded DB/private text or scripting body | 1 | sirmews is not a reliable body search: SQL LIKE is applied to compressed ZDATA. [src/apple_notes_mcp/notes_database.py][sir-40] | Done — `search`; `search_notes`; `query_notes` |
| Fuzzy / prefix search | [antoniorodr/memo][memo]; [cardmagic/notes][card] | AppleScript → fzf; DB → MiniSearch | 1 | memo needs fzf + bat and previews exported bodies; cardmagic uses fuzzy=0.2 and prefix matching. [src/memo_helpers/search_memo.py][memo-41]; [src/searcher.ts][card-42] | Done — `search --fuzzy` |
| FTS5 index | [cardmagic/notes][card] | DB → separate SQLite FTS5 index | 1 | FTS5 exists, but normal search is ranked by MiniSearch. [src/indexer.ts][card-43]; [src/searcher.ts][card-42] | Done — `index`; `query_notes` |
| Semantic / hybrid search | [RafalWilinski/mcp-apple-notes][raf]; [Tom-Semple/mcp-apple-notes-fixed][tom]; [Dan8Oren/mcp-apple-notes][dan]; [disco-trooper/apple-notes-mcp][disco]; [storizzi/notes-exporter][storiz] | JXA/export → LanceDB or Qdrant embeddings | 5 | disco supports chunking, keyword/semantic/hybrid modes and reciprocal-rank fusion; optional remote embeddings. [src/search/chunk-search.ts][disco-44] | Not planned — no embedding model or remote semantic-search dependency |
| Incremental search index / force rebuild | [cardmagic/notes][card]; [disco-trooper/apple-notes-mcp][disco]; [storizzi/notes-exporter][storiz] | DB modification times or JXA/export tracking | 5 | Detect deletes, refresh changed notes, and expose index statistics; not Notes sync. | Done — `index --rebuild`; `query_notes rebuild=true` |
| Background indexing jobs, progress, cancellation | [disco-trooper/apple-notes-mcp][disco] | JXA + local index job manager | 4 | [src/indexing/job-manager.ts][disco-45]; explicit start/get/list/cancel tools. | Done — `index --background|--status|--cancel`; `index_status` |
| Related notes / tag and wiki-link graph | [disco-trooper/apple-notes-mcp][disco] | Text extraction + vector index | 5 | #tags and [[wiki links]] are parsed text, not native Notes tag/link identity. JSON/GraphML export. [src/graph/extract.ts][disco-46] | Done — `backlinks`; `related_notes` |
| Read by UUID, Core Data ID, numeric/short ID or title | [johnmatthewtennant/notekit-cli][mk]; [JaviSoto/apple-notes-cli][javi]; [xwmx/notes-app-cli][xwmx]; [sweetrb/apple-notes-mcp][sweet]; [mattjefferson/honeycrisp][honey]; [biao29/notesctl][biao]; [FradSer/note][frad]; [krasun/notes-mcp][kras]; [henilcalagiya/mcp-apple-notes][hen]; [RodriguesJohn/applenotesmcp][rod]; [Dan8Oren/mcp-apple-notes][dan]; [ailenshen/apple-notes-mcp][ail]; [xiaofeng-han/apple-mcp][xiao]; [shareup/nanotes][nano] | DB identifier bridge; private framework; AppleScript | 1 | Accepted forms differ. notescli already models UUID/Core Data ID; compact IDs and ambiguity candidates need CLI policy. | Done — UUID, Core Data ID, `n<Z_PK>`, bare numeric ID, and unique title |
| Read plaintext / HTML / Markdown | [antoniorodr/memo][memo]; [johnmatthewtennant/notekit-cli][mk]; [JaviSoto/apple-notes-cli][javi]; [xwmx/notes-app-cli][xwmx]; [sweetrb/apple-notes-mcp][sweet]; [danielhopkins/apple-tools][apple]; [mattjefferson/honeycrisp][honey]; [FradSer/note][frad]; [RhetTbull/macnotesapp][mac]; [ailenshen/apple-notes-mcp][ail]; [xiaofeng-han/apple-mcp][xiao]; [mattt/iMCP][imcp] | Scripting HTML conversion or native/protobuf decoding | 1 | HTML conversion alone does not preserve native checklist/tag semantics. | Done — `show`; `get_note` |
| Read raw attributes / structured paragraphs / outline | [johnmatthewtennant/notekit-cli][mk]; [sweetrb/apple-notes-mcp][sweet]; [shareup/nanotes][nano]; [ailenshen/apple-notes-mcp][ail]; [xiaofeng-han/apple-mcp][xiao] | Private framework or protobuf | 1 | notekit reads UTF-16 ranges; nanotes dumps protobuf; xiaofeng reads sections/outline. [notekit-handwritten.m][mk-47] | Done — `raw`; `show --format outline`; collapsed heading state; `get_note format=outline` |
| Read multiple notes in one call | [mcolyer/mcp-apple-notes-py][mcol]; [ailenshen/apple-notes-mcp][ail]; [xiaofeng-han/apple-mcp][xiao] | ScriptingBridge/private framework | 4 | mcolyer get_notes accepts ID arrays; xiaofeng read accepts up to 20 IDs. | Done — `show-many`; `get_notes` |
| Count notes / statistics / selected properties | [xwmx/notes-app-cli][xwmx]; [cardmagic/notes][card]; [sweetrb/apple-notes-mcp][sweet]; [krasun/notes-mcp][kras]; [RhetTbull/apple-notes-parser][rparser] | Scripting or DB aggregation | 1 | krasun registers notes-note-count, not README spelling notes-get-note-count. | Done — `count`; `stats`; `count_notes`; `get_stats` |
| Open/reveal note, folder, account or attachment | [xwmx/notes-app-cli][xwmx]; [sweetrb/apple-notes-mcp][sweet]; [angelespejo/apple-notes-cli][angel]; [RhetTbull/macnotesapp][mac] | AppleScript/ScriptingBridge | 2 | sweetrb exposes all four; other tools expose notes only. | Done — `open` handles notes, folders, accounts, and attachments; `--reveal` uses Finder |
| Read Notes.app selection | [sweetrb/apple-notes-mcp][sweet]; [RhetTbull/macnotesapp][mac] | AppleScript/ScriptingBridge | 1 | macnotesapp dump --selected; no selection field exists in notescli NotesReading. | Done — `selection` |
| Get note deep link | [johnmatthewtennant/notekit-cli][mk]; [sweetrb/apple-notes-mcp][sweet]; [danielhopkins/apple-tools][apple]; [xiaofeng-han/apple-mcp][xiao] | Native UUID/DB or AppleScript fallback | 1 | notes:// and applenotes:// schemes occur; sweetrb fallback needs FDA on macOS 26+. | Done — `deeplink`; `get_deeplink` |
| Paragraph links and persistent anchors | [sweetrb/apple-notes-mcp][sweet] | DB paragraph IDs + local anchor registry | 5 | Create/list/resolve/prune anchors; optional resolver service. [src/services/anchorRegistry.ts][sweet-48] | Done — `anchor add|list|resolve|prune` and matching MCP tools |
| List native note-to-note links / backlinks | [johnmatthewtennant/notekit-cli][mk]; [sweetrb/apple-notes-mcp][sweet]; [threeplanetssoftware/apple_cloud_notes_parser][parser]; [RhetTbull/apple-notes-parser][rparser]; [xiaofeng-han/apple-mcp][xiao] | DB inline attachment records/private framework | 1 | xiaofeng read_note includes backlinks; a web URL run is a different representation. | Done — `link list`; `backlinks`; `link_list`; `list_backlinks` |
| Read native tags and counts | [sweetrb/apple-notes-mcp][sweet]; [threeplanetssoftware/apple_cloud_notes_parser][parser]; [RhetTbull/apple-notes-parser][rparser]; [RhetTbull/macnotesapp][mac]; [xiaofeng-han/apple-mcp][xiao]; [storizzi/notes-exporter][storiz] | DB ICInlineAttachment/ICHashtag or private framework | 1 | honeycrisp and several small MCPs extract textual hashtags only; do not equate those with native tags. | Done — `tags`; `list_tags` |
| Read Smart Folder rules / evaluate results | [sweetrb/apple-notes-mcp][sweet]; [threeplanetssoftware/apple_cloud_notes_parser][parser]; [xiaofeng-han/apple-mcp][xiao] | DB/private framework | 1 | parser exports rules; sweetrb evaluates supported rules and reports unsupported ones. [src/utils/smartFolders.ts][sweet-49] | Done — `smart-folders`; `list_smart_folders` |
| Detect locked notes and skip unreadable content | [JaviSoto/apple-notes-cli][javi]; [cardmagic/notes][card]; [sweetrb/apple-notes-mcp][sweet]; [danielhopkins/apple-tools][apple]; [mattjefferson/honeycrisp][honey]; [RhetTbull/macnotesapp][mac]; [threeplanetssoftware/apple_cloud_notes_parser][parser]; [RhetTbull/apple-notes-parser][rparser]; [ailenshen/apple-notes-mcp][ail]; [xiaofeng-han/apple-mcp][xiao]; [mattt/iMCP][imcp]; [Kylmakalle/apple-notes-exporter][kyl] | DB flags or scripting passwordProtected | 1 | Kylmakalle exports title only. No credential access or unlock is implied. | Done — locked/body-unavailable notes are reported and skipped where required |
| Decrypt password-locked backup notes with supplied password | [threeplanetssoftware/apple_cloud_notes_parser][parser] | Copied DB + cryptographic decoder | 5 | Known legacy Notes password required; device-passcode protection is unsupported. [lib/AppleDecrypter.rb][parser-50] | Not planned — password decryption of backup stores is outside the live Notes product |
| Read Recently Deleted without including it by default | [sweetrb/apple-notes-mcp][sweet]; [mattjefferson/honeycrisp][honey]; [xiaofeng-han/apple-mcp][xiao]; [ailenshen/apple-notes-mcp][ail] | DB/private framework | 1 | honeycrisp opts in through --folder; sweetrb query-notes includeDeleted includes pending/folderless records too. | Done — `deleted`; `list_deleted` |
| Detect shared notes / share participants | [sweetrb/apple-notes-mcp][sweet]; [threeplanetssoftware/apple_cloud_notes_parser][parser]; [coddingtonbear/icloud-md][cloud]; [ailenshen/apple-notes-mcp][ail]; [xiaofeng-han/apple-mcp][xiao] | DB/private framework/CloudKit | 1 | parser decodes participant records; detecting shared state is not invitation/permission management. [lib/AppleCloudKitShareParticipant.rb][parser-51] | Done — JSON note metadata includes shared state and participants |
| Read sync/upload state | [sweetrb/apple-notes-mcp][sweet]; [xiaofeng-han/apple-mcp][xiao]; [ailenshen/apple-notes-mcp][ail] | DB/native version fields | 5 | A successful local save is not proof of remote delivery. [src/utils/syncDetection.ts][sweet-52] | Done — JSON/raw metadata includes sync state |
| Create from plaintext / HTML / Markdown | [antoniorodr/memo][memo]; [johnmatthewtennant/notekit-cli][mk]; [JaviSoto/apple-notes-cli][javi]; [xwmx/notes-app-cli][xwmx]; [cardmagic/notes][card]; [sweetrb/apple-notes-mcp][sweet]; [danielhopkins/apple-tools][apple]; [mattjefferson/honeycrisp][honey]; [biao29/notesctl][biao]; [FradSer/note][frad]; [angelespejo/apple-notes-cli][angel]; [RafalWilinski/mcp-apple-notes][raf]; [Tom-Semple/mcp-apple-notes-fixed][tom]; [krasun/notes-mcp][kras]; [henilcalagiya/mcp-apple-notes][hen]; [RodriguesJohn/applenotesmcp][rod]; [Siddhant-K-code/mcp-apple-notes][sid]; [Dan8Oren/mcp-apple-notes][dan]; [mcolyer/mcp-apple-notes-py][mcol]; [disco-trooper/apple-notes-mcp][disco]; [shareup/nanotes][nano]; [RhetTbull/macnotesapp][mac]; [ailenshen/apple-notes-mcp][ail]; [xiaofeng-han/apple-mcp][xiao] | AppleScript/JXA/ScriptingBridge; Shortcuts/private framework | 2 | Formats vary. Native Markdown headings/checklists need phase 3; Markdown-to-HTML headings often become styled text. | Done — `add`; `create_note`; `write` |
| Read write input from stdin or file | [johnmatthewtennant/notekit-cli][mk]; [JaviSoto/apple-notes-cli][javi]; [mattjefferson/honeycrisp][honey]; [biao29/notesctl][biao]; [FradSer/note][frad]; [sweetrb/apple-notes-mcp][sweet]; [danielhopkins/apple-tools][apple]; [RhetTbull/macnotesapp][mac]; [xiaofeng-han/apple-mcp][xiao] | CLI/file input → write backend | 2 | sweetrb contentPath applies size/path/symlink restrictions; --json stdin is also supported by xiaofeng. | Done — `--stdin` and `--file` |
| Create/edit in $EDITOR | [antoniorodr/memo][memo]; [xwmx/notes-app-cli][xwmx]; [RhetTbull/macnotesapp][mac] | Temporary text + AppleScript/ScriptingBridge | 2 | memo retains image placeholders but appends preserved images at end. [src/memo_helpers/edit_memo.py][memo-53] | Done — `edit` |
| Clip a web page into a note | [RhetTbull/macnotesapp][mac] | HTTP readable-page extraction → ScriptingBridge | 2 | notes add --url; distinct from inserting a URL link/card. [macnotesapp/cli/cli.py][mac] | Done — `clip` |
| Replace body / rename note | [johnmatthewtennant/notekit-cli][mk]; [JaviSoto/apple-notes-cli][javi]; [xwmx/notes-app-cli][xwmx]; [cardmagic/notes][card]; [sweetrb/apple-notes-mcp][sweet]; [mattjefferson/honeycrisp][honey]; [biao29/notesctl][biao]; [FradSer/note][frad]; [henilcalagiya/mcp-apple-notes][hen]; [RodriguesJohn/applenotesmcp][rod]; [Dan8Oren/mcp-apple-notes][dan]; [disco-trooper/apple-notes-mcp][disco]; [RhetTbull/macnotesapp][mac]; [ailenshen/apple-notes-mcp][ail]; [xiaofeng-han/apple-mcp][xiao] | AppleScript/JXA/ScriptingBridge or private framework | 2 | Full HTML replacement can lose rich content; native/diff preservation belongs to phase 3. | Done — `edit`; `rename`; `update_note`; `rename_note` |
| Append text/Markdown | [johnmatthewtennant/notekit-cli][mk]; [JaviSoto/apple-notes-cli][javi]; [sweetrb/apple-notes-mcp][sweet]; [danielhopkins/apple-tools][apple]; [mattjefferson/honeycrisp][honey]; [biao29/notesctl][biao]; [Dan8Oren/mcp-apple-notes][dan]; [RhetTbull/macnotesapp][mac]; [ailenshen/apple-notes-mcp][ail]; [xiaofeng-han/apple-mcp][xiao] | Scripting body rewrite; Shortcuts/native append | 2 | Plain append and native preserving append are different guarantees. | Done — `append`; `append_to_note` |
| Prepend / insert under heading / replace section | [sweetrb/apple-notes-mcp][sweet]; [ailenshen/apple-notes-mcp][ail]; [xiaofeng-han/apple-mcp][xiao] | AppleScript prepend or private framework | 3 | sweetrb update-note supports prepend; ailenshen/xiaofeng target sections without replacing all content. | Done — `prepend`; `insert-under-heading`; `replace-section` and matching MCP tools |
| Exact text/range/line edits using UTF-16 offsets | [johnmatthewtennant/notekit-cli][mk]; [ailenshen/apple-notes-mcp][ail]; [xiaofeng-han/apple-mcp][xiao] | Private NotesShared editing objects | 3 | notekit insert/delete-range/search-offset/replace/delete-line; body-offset excludes title. | Done — `text insert|delete|replace|find` and matching native MCP tools |
| Native paragraph styles, indentation, inline colors/highlights | [johnmatthewtennant/notekit-cli][mk]; [ailenshen/apple-notes-mcp][ail]; [xiaofeng-han/apple-mcp][xiao] | Private framework | 3 | Preserves color, the five-color highlight palette, alignment, writing direction, font name and size, super/subscript, and collapsed headings. | Done — `format paragraph|inline` and matching native MCP tools |
| Create native checklist items | [johnmatthewtennant/notekit-cli][mk]; [sweetrb/apple-notes-mcp][sweet]; [danielhopkins/apple-tools][apple]; [ailenshen/apple-notes-mcp][ail]; [xiaofeng-han/apple-mcp][xiao]; [coddingtonbear/icloud-md][cloud] | Private framework; Shortcuts; CloudKit encoding | 3 | sweetrb adds unchecked items singly or in batches up to 20; HTML bullets are not checklists. | Done — `checklist add`; `checklist_add` |
| Toggle existing checklist item | [johnmatthewtennant/notekit-cli][mk]; [ailenshen/apple-notes-mcp][ail]; [xiaofeng-han/apple-mcp][xiao]; [coddingtonbear/icloud-md][cloud] | Private framework or CloudKit paragraph data | 3 | notekit set-attr --todo-done; sweetrb explicitly marks set-checklist-item unavailable. [src/tools/nativeOperations.ts][sweet-54] | Done — `checklist toggle`; `checklist_toggle` |
| Check/uncheck all; sort or delete completed items | [xiaofeng-han/apple-mcp][xiao] | Private framework | 3 | [Sources/NoteModel/Checklist.swift][xiao-55]; preserve surviving item identities. | Done — `checklist check-all|uncheck-all|clear-done` and matching MCP tools |
| Read native tables with row/column order | [threeplanetssoftware/apple_cloud_notes_parser][parser]; [sweetrb/apple-notes-mcp][sweet]; [danielhopkins/apple-tools][apple]; [coddingtonbear/icloud-md][cloud]; [ailenshen/apple-notes-mcp][ail]; [xiaofeng-han/apple-mcp][xiao]; [dunhamsteve/notesutils][utils]; [mattt/iMCP][imcp] | DB mergeable protobuf/private framework | 1 | A table is a separate object with CRDT row/column identities, not just a text run. | Done — `table show`; `table_get` in Markdown, JSON, or CSV |
| Create native tables | [sweetrb/apple-notes-mcp][sweet]; [danielhopkins/apple-tools][apple]; [ailenshen/apple-notes-mcp][ail]; [xiaofeng-han/apple-mcp][xiao] | Shortcuts/private framework | 3 | sweetrb appends tables; xiaofeng Markdown creates them in place. | Done — `table create`; `table_create` |
| Edit and format table cells | [coddingtonbear/icloud-md][cloud]; [ailenshen/apple-notes-mcp][ail]; [xiaofeng-han/apple-mcp][xiao]; [disco-trooper/apple-notes-mcp][disco] | CloudKit/private framework; disco rewrites scripting HTML | 3 | disco assigns the whole note body; ailenshen may rebuild a table and reset cell formatting. NotesCLI preserves and writes cell attribute runs. [src/notes/crud.ts][disco-56]; [Sources/AppleNotesMCP/MCP/WriteTools.swift][ail] | Done — `table set`; `table format-cell`; `table_set`; `table_format_cell` |
| Insert/delete table rows or columns | [coddingtonbear/icloud-md][cloud]; [xiaofeng-han/apple-mcp][xiao]; [ailenshen/apple-notes-mcp][ail] | CloudKit/private framework | 3 | icloud-md supports one contiguous row OR column change per push; rejects reorder and mixed-axis structural edits. [src/notes/tableEdit.ts][cloud-57] | Done — `table add-row|add-column|remove-row|remove-column` and matching MCP tools |
| Add/remove native tags on a note | [sweetrb/apple-notes-mcp][sweet]; [xiaofeng-han/apple-mcp][xiao] | Shortcuts/private framework | 3 | sweetrb create-note tags is response-only metadata; use add-native-tags. xiaofeng parses native #tags in Markdown. | Done — `tag add|remove`; `tag_add`; `tag_remove` |
| Rename/delete a tag globally | [xiaofeng-han/apple-mcp][xiao] | Private framework | 3 | manage_tag; deletion checks expected note count. sweetrb replace-native-tag is per-note, not global. [Sources/NotesComponent/Tools/WriteTools.swift][xiao-58] | Done — `tag rename|delete`; `tag_rename`; `tag_delete` |
| Pin/unpin note | [johnmatthewtennant/notekit-cli][mk]; [sweetrb/apple-notes-mcp][sweet]; [xiaofeng-han/apple-mcp][xiao] | Private framework/Shortcuts | 3 | Already represented in notescli reads, absent from NotesWriting. | Done — `pin`; `unpin`; `pin_note`; `unpin_note` |
| Insert native note-to-note link | [johnmatthewtennant/notekit-cli][mk]; [sweetrb/apple-notes-mcp][sweet]; [xiaofeng-han/apple-mcp][xiao] | Private inline attachment/Shortcuts | 3 | Keep target UUID and display text; a normal anchor tag is insufficient. | Done — `link add`; `link_add` |
| Insert external web/mail link | [johnmatthewtennant/notekit-cli][mk]; [sweetrb/apple-notes-mcp][sweet]; [ailenshen/apple-notes-mcp][ail]; [xiaofeng-han/apple-mcp][xiao] | Scripting HTML or native attributes | 2 | sweetrb insert-link also has a native note-link route. [src/services/linkInsert.ts][sweet-59] | Done — `format inline --link` |
| Add file attachment / create note with file | [johnmatthewtennant/notekit-cli][mk]; [sweetrb/apple-notes-mcp][sweet]; [RhetTbull/macnotesapp][mac]; [xiaofeng-han/apple-mcp][xiao] | Private framework; AppleScript/ScriptingBridge | 3 | notekit accepts PNG/JPEG; macnotesapp documents duplicate display and PDF scripting limits. | Done — `add --attach`; `attach`; `create_note attachments`; `attach_file` |
| Insert image at a chosen text position | [johnmatthewtennant/notekit-cli][mk]; [xiaofeng-han/apple-mcp][xiao] | Private framework | 3 | notekit uses UTF-16 position; xiaofeng uses a Markdown image at its insertion position. | Done — `attach --position`; `attach_file` |
| Attachment from pasteboard | [sweetrb/apple-notes-mcp][sweet] | Frozen pasteboard → Notes scripting | 3 | Checks retained content and exact attachment bytes. [src/tools/directOperations.ts][sweet-60] | Done — `attach --pasteboard`; `attach_pasteboard` |
| Set image display size; delete native attachment | [johnmatthewtennant/notekit-cli][mk] | Private framework | 3 | insert-image --view small/large; delete-attachment removes marker and attachment. Locked notes refused. | Done — `attach --view`; `attachment delete`; `delete_attachment` |
| Add native URL preview card | [xiaofeng-han/apple-mcp][xiao] | Private framework | 3 | ![](https://…) creates a card. [Sources/NotesComponent/Store/Writing.swift][xiao-61] | Done — `link add-url --card`; `add_url card=true` |
| Preserve existing attachments through Markdown edits | [johnmatthewtennant/notekit-cli][mk]; [ailenshen/apple-notes-mcp][ail]; [xiaofeng-han/apple-mcp][xiao] | Native object references + diff editing | 3 | References belong to their note; missing/foreign references are rejected. ailenshen permits read/preserve, not add/remove. | Done — native `edit`, `write`, `update_note`, and `write_markdown` preserve `notescli-attachment:ID`; scripting refuses loss |
| Duplicate note | [johnmatthewtennant/notekit-cli][mk]; [xiaofeng-han/apple-mcp][xiao] | Private framework | 3 | xiaofeng copy_of copies attachments too; notekit duplicate should not be assumed to clone every media type. | Done — `duplicate`; `duplicate_note` |
| Move note across folders | [antoniorodr/memo][memo]; [johnmatthewtennant/notekit-cli][mk]; [JaviSoto/apple-notes-cli][javi]; [sweetrb/apple-notes-mcp][sweet]; [biao29/notesctl][biao]; [FradSer/note][frad]; [henilcalagiya/mcp-apple-notes][hen]; [Dan8Oren/mcp-apple-notes][dan]; [disco-trooper/apple-notes-mcp][disco]; [RhetTbull/macnotesapp][mac]; [ailenshen/apple-notes-mcp][ail]; [xiaofeng-han/apple-mcp][xiao] | Scripting/private framework | 2 | Account boundaries and shared folders need explicit checks. | Done — `move`; `move_note` |
| Create nested folder / missing parents | [JaviSoto/apple-notes-cli][javi]; [sweetrb/apple-notes-mcp][sweet]; [FradSer/note][frad]; [angelespejo/apple-notes-cli][angel]; [henilcalagiya/mcp-apple-notes][hen]; [RhetTbull/macnotesapp][mac]; [coddingtonbear/icloud-md][cloud]; [xiaofeng-han/apple-mcp][xiao] | Scripting; CloudKit; private framework | 2 | icloud-md infers folders from directories; remote rename/delete is not supported there. | Done — `folder create --parents` |
| Create folder | [johnmatthewtennant/notekit-cli][mk]; [JaviSoto/apple-notes-cli][javi]; [sweetrb/apple-notes-mcp][sweet]; [biao29/notesctl][biao]; [FradSer/note][frad]; [angelespejo/apple-notes-cli][angel]; [henilcalagiya/mcp-apple-notes][hen]; [RhetTbull/macnotesapp][mac]; [ailenshen/apple-notes-mcp][ail]; [xiaofeng-han/apple-mcp][xiao]; [coddingtonbear/icloud-md][cloud] | Scripting/private framework/CloudKit | 2 | Nested-path and automatic-parent behavior are separate capabilities. | Done — `folder create`; `create_folder` |
| Rename folder | [JaviSoto/apple-notes-cli][javi]; [sweetrb/apple-notes-mcp][sweet]; [henilcalagiya/mcp-apple-notes][hen]; [RhetTbull/macnotesapp][mac]; [ailenshen/apple-notes-mcp][ail]; [xiaofeng-han/apple-mcp][xiao] | Scripting/private framework | 2 | Exact folder ID avoids same-name collisions. | Done — `folder rename`; `rename_folder` |
| Delete folder | [johnmatthewtennant/notekit-cli][mk]; [JaviSoto/apple-notes-cli][javi]; [sweetrb/apple-notes-mcp][sweet]; [biao29/notesctl][biao]; [FradSer/note][frad]; [angelespejo/apple-notes-cli][angel]; [henilcalagiya/mcp-apple-notes][hen]; [RhetTbull/macnotesapp][mac]; [ailenshen/apple-notes-mcp][ail]; [xiaofeng-han/apple-mcp][xiao] | Scripting/private framework | 2 | Recursive/empty-folder behavior differs; see guarded deletion below. | Done — `folder delete`; `delete_folder` |
| Move folder / reparent subtree | [henilcalagiya/mcp-apple-notes][hen]; [xiaofeng-han/apple-mcp][xiao] | AppleScript/private framework | 3 | No method in notescli NotesWriting; private route uses account-local hierarchy. | Done — `folder move`; `move_folder` |
| Create/rename/delete tag-based Smart Folder | [xiaofeng-han/apple-mcp][xiao] | Private framework | 3 | Creation supports any/all existing tags; broader Smart Folder rule editing is not established. [Sources/NotesComponent/Store/Organizer.swift][xiao-62] | Done — `smart-folder create|rename|delete` and matching MCP tools |
| Replace broader Smart Folder rules | No inspected peer | Private framework | 3 | NotesShared stores rule JSON. The typed compiler covers tags, dates, folders, checklists, attachment sections, shared, locked, mentions, and Quick Notes; raw JSON covers future predicates. | Done — `smart-folder edit-typed`; `smart-folder edit-rules`; `smart_folder_edit_typed`; `smart_folder_edit_rules` |
| Read and write per-folder sort | No inspected peer | Private framework | 3 | `ICFolderCustomNoteSortType` represents modified, created, and title sort with two directions. Date-header grouping is readable but has no NotesShared setter. | Done — `folder sort`; `get_folder_sort`; `set_folder_sort` |
| Check note/folder existence | [angelespejo/apple-notes-cli][angel]; [paradise-runner/cider][cider]; [shakedlokits/stash][stash] | AppleScript | 1 | angelespejo implements exists; exists-folder is documented and has a function but is not dispatched. | Done — `exists`; `folder exists` |
| Soft delete with account-correct Recently Deleted | [johnmatthewtennant/notekit-cli][mk]; [danielhopkins/apple-tools][apple]; [sweetrb/apple-notes-mcp][sweet]; [ailenshen/apple-notes-mcp][ail]; [xiaofeng-han/apple-mcp][xiao]; [coddingtonbear/icloud-md][cloud] | AppleScript/private framework/CloudKit | 2 | notekit refuses a second delete in trash; notescli forbids hard deletion already. [notekit-generated.m][mk-63] | Done — `delete`; `delete_note` |
| Restore a note from Recently Deleted | [ailenshen/apple-notes-mcp][ail]; [xiaofeng-han/apple-mcp][xiao] | Native state + Notes scripting move | 3 | icloud-md restore only reverts a local file; do not map it to trash restore. | Done — `restore`; `restore_note` |
| Batch move/delete with partial outcomes | [sweetrb/apple-notes-mcp][sweet]; [disco-trooper/apple-notes-mcp][disco]; [xiaofeng-han/apple-mcp][xiao] | Scripting/private framework | 4 | Not atomic. sweetrb tracks landed/uncertain/unattempted operations; xiaofeng checks versions. | Done — CLI selection batches; `batch_move_notes`; `batch_delete_notes` |
| Guard recursive folder deletion with expected count | [sweetrb/apple-notes-mcp][sweet]; [ailenshen/apple-notes-mcp][ail]; [xiaofeng-han/apple-mcp][xiao] | Preflight DB/native state + scripting | 4 | Check descendants, locked/shared notes and expected_notes before mutation. | Done — recursive `folder delete --expect-count` with in-script container checks |
| Permanent delete / raw CloudKit repair | [coddingtonbear/icloud-md][cloud] | CloudKit records/modify | 5 | delete --hard and object delete exist upstream; excluded by notescli SPEC, not a parity target. | Not planned — permanent deletion and CloudKit repair violate the soft-delete safety policy |
| Read-only process mode | [JaviSoto/apple-notes-cli][javi]; [Dan8Oren/mcp-apple-notes][dan]; [disco-trooper/apple-notes-mcp][disco] | CLI/server mutation guards | 4 | Hides/blocks Notes writes; index/export can still write local files. Not the same as SQLite read-only access. | Done — global `--read-only`; MCP hides write tools |
| Restrict writes to approved folder trees | [xiaofeng-han/apple-mcp][xiao] | Private/framework request guard | 4 | APPLE_NOTES_MCP_WRITE_FOLDERS covers notes, folders and global tag changes. [Sources/NotesComponent/Store/FolderGuard.swift][xiao-64] | Done — `--write-folders`, `NOTESCLI_WRITE_FOLDERS`, and MCP `write_folders` |
| Optimistic concurrency / reject stale edits | [sweetrb/apple-notes-mcp][sweet]; [ailenshen/apple-notes-mcp][ail]; [xiaofeng-han/apple-mcp][xiao]; [coddingtonbear/icloud-md][cloud]; [disco-trooper/apple-notes-mcp][disco] | Content hashes/change tags or HTML+date comparison | 4 | notescli WriteResult describes outcome but no expected revision input exists. disco guard is implemented for table edits. | Done — `--if-modified`; `--expect-revision`; MCP equivalents |
| Post-write readback / unknown-timeout outcome | [sweetrb/apple-notes-mcp][sweet]; [danielhopkins/apple-tools][apple]; [xiaofeng-han/apple-mcp][xiao]; [FradSer/note][frad] | Fresh DB/native/scripting read | 2 | notescli already requires verified/unverified/unknown; rich checks must compare object identity, not text alone. | Done — verified readback, journaled unknown outcomes, and structured errors |
| Rehearse edits / dry-run / backups before write | [johnmatthewtennant/notekit-cli][mk]; [coddingtonbear/icloud-md][cloud]; [ailenshen/apple-notes-mcp][ail]; [xiaofeng-han/apple-mcp][xiao]; [storizzi/notes-exporter][storiz] | Native copied body or local snapshots | 5 | notekit --dry-run/--backup; xiaofeng rehearses native edits before save; icloud-md validates encoding before upload. | Done — `--dry-run`, snapshots, `history`, `undo`, `revert`, and native `--backup` |
| Wait for iCloud acknowledgement | [xiaofeng-han/apple-mcp][xiao]; [ailenshen/apple-notes-mcp][ail] | Private upload/version state + AppleScript save trigger | 5 | Bounded waits; xiaofeng --no-wait reports upload requested. notekit triggers upload but does not promise remote delivery. | Done — `--wait-sync`, `wait-sync` command; MCP `wait_sync`; timeout reports `syncPending` without retrying |
| Permission/capability diagnostics | [sweetrb/apple-notes-mcp][sweet]; [danielhopkins/apple-tools][apple]; [biao29/notesctl][biao]; [xiaofeng-han/apple-mcp][xiao]; [ailenshen/apple-notes-mcp][ail] | Automation/FDA/Shortcuts/native probes | 4 | Distinguish installed bridge, OS support, consent, and verified operation availability. | Done — `doctor`; `engine doctor`; `permissions` |
| Machine output / structured errors / quiet mode | [JaviSoto/apple-notes-cli][javi]; [sweetrb/apple-notes-mcp][sweet]; [mattjefferson/honeycrisp][honey]; [biao29/notesctl][biao]; [FradSer/note][frad]; [johnmatthewtennant/notekit-cli][mk]; [xiaofeng-han/apple-mcp][xiao]; [dogsheep/apple-notes-to-sqlite][dog]; [storizzi/notes-exporter][storiz]; [RhetTbull/apple-notes-parser][rparser] | CLI/MCP serialization | 4 | biao JSON/TSV/quiet output does not guarantee JSON errors: router prints errors through Console. [Sources/notesctl/CommandRouter.swift][biao] | Done — JSON, structured errors, and global `--quiet` |
| Report incomplete search/read/export | [sweetrb/apple-notes-mcp][sweet]; [xiaofeng-han/apple-mcp][xiao]; [mattt/iMCP][imcp]; [storizzi/notes-exporter][storiz] | Decoder + bounded response handling | 4 | imcp unreadableNoteIDs, sweetrb scan truncation/byte budgets, exporter per-note skips; do not silently claim complete results. | Done — fetch, read, sync, and export report incomplete items |
| Paginate by stable cursor / response byte budget | [sweetrb/apple-notes-mcp][sweet]; [mattt/iMCP][imcp] | DB cursor + MCP serialization | 4 | notescli NoteQuery has limit but no cursor; sweetrb tables/transcripts also bound serialized bytes. | Done — CLI and MCP use opaque sort-key plus ID cursors within 48 KB pages |
| MCP tool: search | [cardmagic/notes][card]; [sweetrb/apple-notes-mcp][sweet]; [RafalWilinski/mcp-apple-notes][raf]; [Tom-Semple/mcp-apple-notes-fixed][tom]; [sirmews/apple-notes-mcp][sir]; [henilcalagiya/mcp-apple-notes][hen]; [RodriguesJohn/applenotesmcp][rod]; [Siddhant-K-code/mcp-apple-notes][sid]; [Dan8Oren/mcp-apple-notes][dan]; [mcolyer/mcp-apple-notes-py][mcol]; [disco-trooper/apple-notes-mcp][disco]; [ailenshen/apple-notes-mcp][ail]; [xiaofeng-han/apple-mcp][xiao]; [mattt/iMCP][imcp] | stdio MCP → underlying reader/index | 4 | Names differ; exact registrations are in section 2. | Done — `search_notes`; `query_notes` |
| MCP tool: read/list/accounts/folders | [cardmagic/notes][card]; [sweetrb/apple-notes-mcp][sweet]; [RafalWilinski/mcp-apple-notes][raf]; [Tom-Semple/mcp-apple-notes-fixed][tom]; [sirmews/apple-notes-mcp][sir]; [krasun/notes-mcp][kras]; [henilcalagiya/mcp-apple-notes][hen]; [RodriguesJohn/applenotesmcp][rod]; [Siddhant-K-code/mcp-apple-notes][sid]; [Dan8Oren/mcp-apple-notes][dan]; [mcolyer/mcp-apple-notes-py][mcol]; [disco-trooper/apple-notes-mcp][disco]; [ailenshen/apple-notes-mcp][ail]; [xiaofeng-han/apple-mcp][xiao]; [mattt/iMCP][imcp] | stdio MCP → DB/scripting/private framework | 4 | Expose metadata without repeatedly fetching full bodies. | Done — read/list/account/folder MCP tools |
| MCP tool: create/edit/move/delete | [cardmagic/notes][card]; [sweetrb/apple-notes-mcp][sweet]; [RafalWilinski/mcp-apple-notes][raf]; [Tom-Semple/mcp-apple-notes-fixed][tom]; [krasun/notes-mcp][kras]; [henilcalagiya/mcp-apple-notes][hen]; [RodriguesJohn/applenotesmcp][rod]; [Siddhant-K-code/mcp-apple-notes][sid]; [Dan8Oren/mcp-apple-notes][dan]; [mcolyer/mcp-apple-notes-py][mcol]; [disco-trooper/apple-notes-mcp][disco]; [ailenshen/apple-notes-mcp][ail]; [xiaofeng-han/apple-mcp][xiao] | stdio MCP → write backend | 4 | Tool sets differ: Rafal/Tom/Siddhant/mcolyer create only; cardmagic lacks move. | Done — scripting and opt-in native write MCP tools |
| MCP resources and prompts | [sweetrb/apple-notes-mcp][sweet]; [sirmews/apple-notes-mcp][sir] | MCP resource/prompt handlers | 4 | sweetrb accounts/folders/stats/note resources; find-note, weekly-review, new-meeting-note prompts. [src/tools/resourcesAndPrompts.ts][sweet-65] | Done — `notes://folders`, `notes://note/{uuid}`, `find_note`, `weekly_review` |
| MCP attachment image/audio/file response | [sweetrb/apple-notes-mcp][sweet]; [ailenshen/apple-notes-mcp][ail]; [xiaofeng-han/apple-mcp][xiao] | Local asset resolution + MCP content blocks | 4 | Separate original bytes from resized previews, PDF text and extracted recognition. | Done — `get_attachment` returns bounded image/audio blocks or a resource link |
| MCP remote AppleScript execution | [honeybluesky/my-apple-remembers][memory] | SSH → osascript | 4 | Two tools accept scripts for recall/save; broad execution, no fixed Notes CRUD contract. | Not planned — remote AppleScript execution is outside the local security boundary |
| Same operation through CLI and MCP / JSON dispatch | [cardmagic/notes][card]; [xiaofeng-han/apple-mcp][xiao] | CLI routes share operations with MCP | 4 | xiaofeng call TOOL JSON and tool-specific commands; CLI aliases must preserve the same guards. | Done — CLI and MCP use the same readers, writers, safety journal, and schemas |
| Agent skill/client setup and permissions app | [johnmatthewtennant/notekit-cli][mk]; [sweetrb/apple-notes-mcp][sweet]; [xiaofeng-han/apple-mcp][xiao]; [ailenshen/apple-notes-mcp][ail]; [disco-trooper/apple-notes-mcp][disco] | Local CLI/setup helper | 4 | Convenience setup is distinct from Notes functionality; never infer permission grants from installation. | Done — `setup`; `permissions`; `mcp install|uninstall|status` |
| Export one/all notes as Markdown | [antoniorodr/memo][memo]; [johnmatthewtennant/notekit-cli][mk]; [JaviSoto/apple-notes-cli][javi]; [sweetrb/apple-notes-mcp][sweet]; [danielhopkins/apple-tools][apple]; [mattjefferson/honeycrisp][honey]; [FradSer/note][frad]; [coddingtonbear/icloud-md][cloud]; [RhetTbull/macnotesapp][mac]; [storizzi/notes-exporter][storiz]; [Kylmakalle/apple-notes-exporter][kyl]; [ailenshen/apple-notes-mcp][ail]; [xiaofeng-han/apple-mcp][xiao] | Scripting/Shortcuts; DB/private; CloudKit | 1 | Scope varies: honeycrisp/apple-tools export one; FradSer prints Markdown but has no export command. | Done — `export --format markdown`; `export_notes` |
| Export folder tree with original attachments | [sweetrb/apple-notes-mcp][sweet]; [coddingtonbear/icloud-md][cloud]; [storizzi/notes-exporter][storiz]; [ailenshen/apple-notes-mcp][ail]; [xiaofeng-han/apple-mcp][xiao] | DB/private/CloudKit asset resolution; scripting exporter | 1 | Missing local media must be reported; icloud-md shared attachment downloads remain unverified upstream. | Done — `export --attachments`; `export_notes` |
| HTML export with media / standalone HTML | [threeplanetssoftware/apple_cloud_notes_parser][parser]; [dunhamsteve/notesutils][utils]; [sweetrb/apple-notes-mcp][sweet]; [storizzi/notes-exporter][storiz]; [Kylmakalle/apple-notes-exporter][kyl] | DB asset extraction or Shortcuts/AppleScript | 1 | parser reconstructs rich HTML; sweetrb can embed assets; Kylmakalle images only, no drawings. | Done — `export --format html --embed-media`; `export_notes` |
| Basic HTML export / attachment-name inventory | [xwmx/notes-app-cli][xwmx]; [antoniorodr/memo][memo]; [alexwlchan/notes-export][alex]; [dogsheep/apple-notes-to-sqlite][dog] | AppleScript | 1 | alex overwrites equal titles and does not copy attachments. xwmx has an undocumented --attachments path with old Media-directory assumptions. | Done — HTML export and `attachments` inventory |
| Export JSON / NDJSON / normalized SQLite | [threeplanetssoftware/apple_cloud_notes_parser][parser]; [RhetTbull/apple-notes-parser][rparser]; [sweetrb/apple-notes-mcp][sweet]; [shareup/nanotes][nano]; [dogsheep/apple-notes-to-sqlite][dog]; [JaviSoto/apple-notes-cli][javi] | DB/protobuf or scripting → files | 1 | dogsheep SQLite is an output DB, not the Notes read backend; --dump emits NDJSON. | Done — JSON, NDJSON, and SQLite export; `export_notes` |
| Export PDF / DOCX / EPUB | [storizzi/notes-exporter][storiz] | Export HTML → Chrome/Pandoc/EPUB builder | 5 | EPUB can combine folder notes into chapters; external converters required. [README.md][storiz-66] | Done — in-process paginated PDF, DOCX/RTF, and EPUB 3 export; PDF supports `--combine` |
| Export Bear / Quiver / Joplin formats | [dunhamsteve/notesutils][utils]; [mattrose/AppleNotes2Joplin][joplin] | DB decoders or AppleScript UI copy | 5 | notes2bear omits tables; Joplin script omits images/nested folders and uses foreground UI. | Done — Bear TextBundle, Joplin RAW, and Quiver library export |
| Zip archive of folder and attachments | [ailenshen/apple-notes-mcp][ail]; [xiaofeng-han/apple-mcp][xiao] | Private framework export + ZIP | 5 | Output must be a new destination; locked notes are recorded as skipped. | Done — `export --format zip`; `export_notes format=zip` |
| Template-based Markdown/frontmatter export | [sweetrb/apple-notes-mcp][sweet]; [johnmatthewtennant/notekit-cli][mk]; [storizzi/notes-exporter][storiz] | Export renderers/template engine | 5 | sweetrb manages saved templates and previews; notekit selects metadata fields/round-trip markers. | Done — export templates and filename templates are exposed in MCP |
| Stable filenames, duplicate titles, original dates | [Kylmakalle/apple-notes-exporter][kyl]; [JaviSoto/apple-notes-cli][javi]; [johnmatthewtennant/notekit-cli][mk]; [coddingtonbear/icloud-md][cloud]; [storizzi/notes-exporter][storiz]; [threeplanetssoftware/apple_cloud_notes_parser][parser] | Export identity + filesystem metadata | 1 | Kylmakalle disambiguates equal titles with creation date; UUIDs are safer than filenames for sync. | Done — stable UUID filenames, duplicate disambiguation, and date metadata |
| Incremental export manifest / hashes / prune / reconciliation | [storizzi/notes-exporter][storiz] | AppleScript + trackers + filesystem | 5 | Only a complete folder scan marks deletions; retains locally edited Markdown when pruning. [build_manifest.py][storiz-67]; [prune_deleted.py][storiz-68] | Done — export manifest, hashes, unchanged detection, and prune |
| HTTP export service / scheduled jobs | [storizzi/notes-exporter][storiz] | Authenticated local HTTP + launchd | 5 | Service/users/API keys/scopes plus manifest/file access; distinct from MCP. [notes_service/cli.py][storiz-69] | Not planned — no HTTP service; MCP and local daemons are the supported service surfaces |
| Two-way single-file Markdown push/pull/diff | [shakedlokits/stash][stash]; [paradise-runner/cider][cider] | AppleScript + Pandoc + frontmatter ID | 5 | Whole-body replacement; no three-way merge. cider additionally accepts directories recursively. [internal/cli/files.go][cider-70] | Done — `file pull|push|diff` and MCP equivalents use `notes-id`, sidecar merge bases, conflict markers, attachment-loss refusal, dry-run, and persisted unknown outcomes |
| Two-way Markdown folder sync / polling daemon | [johnmatthewtennant/notekit-cli][mk]; [coddingtonbear/icloud-md][cloud]; [storizzi/notes-exporter][storiz] | Private framework; CloudKit; AppleScript | 5 | notekit daemon polls; icloud-md is manual fetch/push with no daemon; exporter can schedule runs. | Done — `sync`; `sync-daemon`; `watch`; `sync_notes` |
| Sync conflict detection / three-way merge | [coddingtonbear/icloud-md][cloud]; [johnmatthewtennant/notekit-cli][mk]; [storizzi/notes-exporter][storiz] | Local base copies + remote revisions | 5 | icloud-md merges nonoverlapping edits; notekit Notes wins and saves .local-conflict; exporter abort/local/remote modes. | Done — three-way merge and conflict markers |
| Sync creates/deletes/moves/folder hierarchy | [coddingtonbear/icloud-md][cloud]; [johnmatthewtennant/notekit-cli][mk]; [storizzi/notes-exporter][storiz] | CloudKit/private/scripting reconciliation | 5 | icloud-md mirrors folder changes; local folder rename creates a new remote folder and moves notes. notekit preserves one-sided deletions by default. | Done — sync creates, restores, deletes, moves, and creates folder hierarchy |
| Version history / diff / revert | [coddingtonbear/icloud-md][cloud] | CloudKit snapshots + local history | 5 | restore discards local changes; revert uploads a historical version; neither is Recently Deleted recovery. | Partial — lossless native snapshot restore with persisted structural readback; scripting refusal or explicit `--allow-downgrade`; setting and Smart Folder rule preimages by journal operation ID. Native attachment restore requires the original Notes attachment object. |
| Obsidian filename-as-title / frontmatter preservation | [coddingtonbear/icloud-md][cloud] | Markdown filesystem/CloudKit | 5 | Title mode fixed at clone; local frontmatter is not uploaded; unsupported Markdown remains literal text. | Done — `export --obsidian` and sync frontmatter IDs |
| Cloudflare cross-device sync / encrypted note bodies | [FradSer/note][frad] | AppleScript → encrypted Worker/D1 API | 5 | Body encryption only; last-write-wins, folder exclusions, preferences and launchd daemon. [Sources/NoteCommands/SharedSyncCommands.swift][frad-71] | Not planned — an external Cloudflare encrypted service is outside the local product |
| Decode legacy stores / Mac/iTunes/physical backups | [threeplanetssoftware/apple_cloud_notes_parser][parser] | Copied SQLite + versioned protobuf | 5 | Also emits CSV/JSON and participant metadata; adds decoded columns to output copy, not a Notes writer. | Not planned — legacy backup decoding is outside the live macOS Notes store scope |
| Inspect raw protobuf / unknown objects without loss | [shareup/nanotes][nano]; [threeplanetssoftware/apple_cloud_notes_parser][parser] | DB raw fields / generic object fallback | 1 | Generic placeholder or byte dump is not a semantic decoder. [commands/dump.ts][nano-72] | Done — `raw`; `get_raw_note` |
| List/save/fetch attachment originals and metadata | [sweetrb/apple-notes-mcp][sweet]; [RhetTbull/apple-notes-parser][rparser]; [threeplanetssoftware/apple_cloud_notes_parser][parser]; [shareup/nanotes][nano]; [xwmx/notes-app-cli][xwmx]; [ailenshen/apple-notes-mcp][ail]; [xiaofeng-han/apple-mcp][xiao] | DB/native media paths or scripting inventory | 1 | nano/xwmx list metadata; rparser/parser/sweetrb copy bytes; not every on-disk asset is downloaded. | Done — `attachments --save`; `save_attachment`; `fetch` |
| PDF text in search | [cardmagic/notes][card] | DB PDF asset + pdftotext | 1 | cardmagic only finds cached PDF assets and needs pdftotext; source hard-codes attachment entity 5. [src/attachments.ts][card-73] | Done — indexed PDF text is searchable |
| Stored OCR text of scans/images; handwriting/labels | [ailenshen/apple-notes-mcp][ail]; [xiaofeng-han/apple-mcp][xiao]; [sweetrb/apple-notes-mcp][sweet] | Private recognition fields or DB summaries | 1 | ailenshen/xiaofeng expose OCR + image labels; sweetrb Paper path exposes handwriting. Recognition may be absent/wrong. | Done — OCR, handwriting, labels, and summaries are decoded and indexed |
| Search attachment OCR, handwriting and audio transcript | [xiaofeng-han/apple-mcp][xiao] | Private attachment metadata + recording mergeable data | 1 | [Sources/NotesComponent/Store/Search.swift][xiao-74]; notescli text query does not specify these sources. | Done — `search --index`; `query_notes` search OCR, handwriting, transcript, and PDF fields |
| Export scans as ordered pages / PDF | [threeplanetssoftware/apple_cloud_notes_parser][parser]; [sweetrb/apple-notes-mcp][sweet]; [ailenshen/apple-notes-mcp][ail]; [xiaofeng-han/apple-mcp][xiao] | Gallery child order + cached scan files/private framework | 1 | Ruby decodes gallery order; xiaofeng/ailenshen sort child assets by creation date, not the gallery CRDT. | Done — `export --scans-pdf` assembles each gallery in stored page order |
| Read/export drawings as fallback raster | [threeplanetssoftware/apple_cloud_notes_parser][parser]; [sweetrb/apple-notes-mcp][sweet]; [ailenshen/apple-notes-mcp][ail]; [xiaofeng-han/apple-mcp][xiao]; [dunhamsteve/notesutils][utils] | DB/private fallback image generations | 1 | sweetrb reports stale fallback generations; modern com.apple.paper is not a normal JPEG attachment. | Done — fallback drawing assets are exposed through attachment reads/exports |
| Decode classic drawing strokes / SVG | [sweetrb/apple-notes-mcp][sweet]; [dunhamsteve/notesutils][utils] | PencilKit/public helper or legacy protobuf | 1 | sweetrb supports com.apple.drawing(.2), not modern Paper stroke data. [src/utils/noteDrawings.ts][sweet-75] | Done — classic PencilKit and stored point strokes render as SVG; raster remains the fallback |
| Analyze exported SVG geometry/text | [sweetrb/apple-notes-mcp][sweet] | SVG parser/geometry utilities | 4 | analyze-svg operates on SVG; it does not create/edit a Notes drawing. [src/tools/svgAnalysis.ts][sweet-76] | Not planned — standalone SVG analysis is not a Notes operation |
| Read original audio / recording fragments | [threeplanetssoftware/apple_cloud_notes_parser][parser]; [sweetrb/apple-notes-mcp][sweet]; [ailenshen/apple-notes-mcp][ail]; [xiaofeng-han/apple-mcp][xiao]; [coddingtonbear/icloud-md][cloud] | Media paths + DB/private recording metadata | 1 | parser copies audio but does not decode its transcript; recordings can contain multiple child fragments. | Done — recording/audio originals are exposed through attachments and export |
| Decode stored audio transcript | [sweetrb/apple-notes-mcp][sweet]; [danielhopkins/apple-tools][apple]; [xiaofeng-han/apple-mcp][xiao] | ZMERGEABLEDATA CRDT/private recording object | 1 | No transcript means none stored; xiaofeng exposes flattened native text, while sweetrb/apple-tools expose segment timing. [src/utils/audioTranscripts.ts][sweet-77]; [notes/mergeable.py][apple-78] | Done — stored transcript text and recording segments are decoded |
| Read Apple-generated recording summary/call metadata | [danielhopkins/apple-tools][apple]; [xiaofeng-han/apple-mcp][xiao] | DB mergeable recording/native metadata | 1 | top-line summary and longer summary may be independently absent; notescli Attachment lacks both. | Done — recording summaries and call metadata are decoded |
| Generate new on-device audio transcript | [sweetrb/apple-notes-mcp][sweet] | Public Speech framework helper | 5 | SpeechAnalyzer on suitable macOS 26 SDK; older SFSpeechRecognizer needs permission/model. Does not write a native Notes transcript. [src/services/noteTranscription.ts][sweet-79] | Not planned — generating a new transcript does not create a native Notes transcript |
| Preview video frame / resized image / PDF text | [ailenshen/apple-notes-mcp][ail]; [xiaofeng-han/apple-mcp][xiao] | AVFoundation/ImageIO/PDFKit over attachment files | 4 | Derivatives for MCP context; preserve original media separately. [Sources/NotesComponent/Tools/AttachmentTool.swift][xiao-80] | Done — `attachments --preview` writes resized images, first video frames, and first PDF pages |
| Read math-result/graph-expression inline objects and dividers | [threeplanetssoftware/apple_cloud_notes_parser][parser]; [xiaofeng-han/apple-mcp][xiao] | DB inline metadata/private framework | 1 | parser covers calculation alt text; xiaofeng also handles dividerline. No mathematical recomputation implied. | Done — inline math and divider objects are retained in structured/raw reads |
| Read native mentions and participant identity | [threeplanetssoftware/apple_cloud_notes_parser][parser]; [RhetTbull/apple-notes-parser][rparser]; [sweetrb/apple-notes-mcp][sweet]; [xiaofeng-han/apple-mcp][xiao] | Inline attachment metadata/private framework | 1 | Reading an existing mention does not imply creating one. [src/apple_notes_parser/embedded_objects.py][rparser-81] | Done — Markdown and JSON include stored mention name, email, and user ID |
| Insert math expressions, divider lines, and shared-note mentions | No inspected peer | Private framework | 3 | Notes computes math results and graphs; mention writes require an existing shared participant record. | Partial — `format math|divider|mention` and MCP equivalents create checked native inline objects |
| Convert a native table to text | No inspected peer | Private framework | 3 | Conversion deletes the native table after replacing its marker with tab- or comma-separated text. | Done — `table convert-to-text`; `table_convert_to_text` |
| Edit shared notes with explicit shared-state guards | [coddingtonbear/icloud-md][cloud]; [ailenshen/apple-notes-mcp][ail]; [xiaofeng-han/apple-mcp][xiao] | CloudKit/private framework | 3 | icloud-md allows shared create/edit, not shared delete/move/rename. Invitation and access-right management remain absent. | Done — native writes require `--allow-shared` or `allow_shared` and refuse read-only or unknown roles |
| Local note descriptions / agent memory metadata | [ailenshen/apple-notes-mcp][ail]; [xiaofeng-han/apple-mcp][xiao] | Local metadata sidecar | 4 | describe_note stores descriptions separately from the note body; not a native Notes summary field. | Not planned — local agent-description sidecars are not native Notes data |
| Preserve Notes display order in export | [threeplanetssoftware/apple_cloud_notes_parser][parser] | DB ordering metadata | 1 | --retain-display-order differs from creation/modification sorting. | Done — `export --order display|modified|created|title`; display is default and order is recorded in the manifest and index |
| Multiple accounts, including local/IMAP fallback | [RhetTbull/macnotesapp][mac]; [JaviSoto/apple-notes-cli][javi]; [xwmx/notes-app-cli][xwmx]; [mattjefferson/honeycrisp][honey] | ScriptingBridge/AppleScript; DB where available | 1 | Selecting a read account is not enough: creation and folder resolution must also be account-aware. | Done — account-aware reads, creates, folders, moves, and local/IMAP metadata |
| Attachment filesystem scope / frozen input bytes | [sweetrb/apple-notes-mcp][sweet] | Regular-file checks, path rules, hashing | 4 | Protect attachment reads/writes and verify inserted bytes; native helper availability does not establish these guarantees. [src/tools/directOperations.ts][sweet-60] | Done — every attachment input is frozen privately, SHA-256 hashed, and checked against stored media |
| Markdown import into an existing/new note | [johnmatthewtennant/notekit-cli][mk]; [coddingtonbear/icloud-md][cloud]; [shakedlokits/stash][stash]; [paradise-runner/cider][cider] | Private framework/CloudKit/AppleScript | 3 | notekit import and write-markdown retain round-trip markers; simple Markdown→HTML import is phase 2. | Done — `add --file`; `write`; `write_markdown` |
| Delete note through CLI/MCP | [antoniorodr/memo][memo]; [johnmatthewtennant/notekit-cli][mk]; [JaviSoto/apple-notes-cli][javi]; [xwmx/notes-app-cli][xwmx]; [cardmagic/notes][card]; [sweetrb/apple-notes-mcp][sweet]; [danielhopkins/apple-tools][apple]; [mattjefferson/honeycrisp][honey]; [biao29/notesctl][biao]; [FradSer/note][frad]; [angelespejo/apple-notes-cli][angel]; [henilcalagiya/mcp-apple-notes][hen]; [RodriguesJohn/applenotesmcp][rod]; [Dan8Oren/mcp-apple-notes][dan]; [disco-trooper/apple-notes-mcp][disco]; [RhetTbull/macnotesapp][mac]; [ailenshen/apple-notes-mcp][ail]; [xiaofeng-han/apple-mcp][xiao]; [coddingtonbear/icloud-md][cloud] | Scripting/private framework/CloudKit | 2 | Deletion is implemented; explicit Recently Deleted guarantees and hard-delete exceptions are listed separately. | Done — `delete`; `delete_note` |
| Audio transcript word timing / speakers / fragment boundaries | [sweetrb/apple-notes-mcp][sweet]; [danielhopkins/apple-tools][apple] | Recording mergeable-data decoder | 1 | Unlike flattened transcript text; apple-tools can select recordings and output timed segments. [notes/mergeable.py][apple-78]; [src/utils/audioTranscripts.ts][sweet-77] | Done — transcript segments retain timing, speaker, and fragment metadata |
| Sort notes by last-opened time | [xiaofeng-han/apple-mcp][xiao] | Private Notes metadata | 1 | Distinct from creation/modification date; exposed as sort=opened. [Sources/NotesComponent/Tools/ReadTools.swift][xiao-82] | Done — `list --sort opened`; `list_notes sort=opened` |

## 2. CLI commands and MCP tool names

Commands below are public entry points, aliases, operational scripts and hidden commands found in dispatchers. Routine help/version flags are omitted unless they are commands; options are shown where they select a distinct operation. “MCP: none” means no server in that repository. Build/test/package-manager scripts are excluded, except the Makefile that is Kylmakalle’s user interface. Names containing hyphens and underscores are copied exactly.

### antoniorodr/memo

[README][memo-115] · [src/memo/memo.py][memo] · commit `1cf73cd47dff`.

CLI: `memo notes` (list by default): `--folder/-f`, `--add/-a`, `--edit/-e`, `--delete/-d`, `--move/-m`, `--flist/-fl`, `--search/-s`, `--remove/-r` (folder), `--export/-ex`, `--no-cache/-nc`, `--view/-v`. `memo rem` has `--complete`, `--add`, `--delete`, `--edit` (Reminders, outside Notes scope).

MCP: none.

### johnmatthewtennant/notekit-cli

[README][mk-116] · [notekit.m][mk] · commit `dcfdb5b25b89`.
Other definitions: [notekit-handwritten.m][mk-47]; [notekit-generated.m][mk-63].

CLI: `notekit`: `--help`, `-h`, `--version`, `version`, `folders`, `install-skill`, `test`, `list`, `get`, `read`, `read-attrs`, `read-structured`, `read-markdown`, `write-markdown`, `set-attr`, `move`, `search`, `pin`, `unpin`, `duplicate`, `create-folder`, `delete-folder`, `create-empty`, `create-markdown`, `create`, `delete`, `append`, `insert`, `insert-image`, `delete-attachment`, `delete-range`, `search-offset`, `replace`, `delete-line`, `get-link`, `add-link`, `add-note-link`, `export`, `import`, `sync`, `sync-daemon`, `sync-resolve-conflict`.

MCP: none.

### JaviSoto/apple-notes-cli

[README][javi-117] · [src/cli.rs][javi] · commit `aabdb456ab74`.

CLI: `apple-notes accounts list`; `folders list/create/rename/delete`; `notes list/show/create/rename/set-body/append/move/delete`; `export`; hidden `backup export`. Global `--read-only`, `--backend`, `--json`.

MCP: none.

### xwmx/notes-app-cli

[README][xwmx-118] · [notes-app][xwmx] · commit `422798ace09c`.

CLI: `notes-app`: `accounts [show]`, `add`, `attachments`, `commands`, `count`, `delete`, `edit`, `export [--attachments]`, `folders [show]`, `list`, `show [--open]`, `update`, `help`, `version`.

MCP: none.

### cardmagic/notes

[README][card-119] · [src/cli.ts][card] · commit `7445e3f3f13f`.
Other definitions: [src/mcp.ts][card-120].

CLI: `notes`: `search`, `recent`, `read`, `folder`, `folders`, `index`, `stats`, `create`, `delete`, `edit`; `--mcp` starts the server.

MCP: `search_notes`, `recent_notes`, `read_note`, `list_folders`, `notes_in_folder`, `get_note_stats`, `create_note`, `delete_note`, `edit_note`.

### sweetrb/apple-notes-mcp

[README][sweet-121] · [src/index.ts][sweet] · commit `3dbf1538cedf`.
Other definitions: [src/tools/directOperations.ts][sweet-60]; [src/tools/folderDelete.ts][sweet-122]; [src/tools/markdownTemplates.ts][sweet-123]; [src/tools/nativeOperations.ts][sweet-54]; [src/tools/nativeTagsBridge.ts][sweet-124]; [src/tools/privateHelperTools.ts][sweet-125]; [src/tools/svgAnalysis.ts][sweet-76]; [src/tools/resourcesAndPrompts.ts][sweet-65].

CLI: `apple-notes-mcp` starts MCP; `setup` (`--public-helper`, `--native-helper`, `--permissions-window`, `--permissions`, `--broker`, `--gemini-spark`, `--check`); `templates edit`; `anchors serve`; `help`, `version`.

MCP: `create-note`, `search-notes`, `query-notes`, `get-note-content`, `get-note-plaintext`, `get-note-by-id`, `get-note-details`, `show-note`, `get-note-link`, `show-folder`, `show-account`, `get-native-objects`, `get-note-tables`, `get-note-blocks`, `list-note-paragraphs`, `get-paragraph-link`, `create-paragraph-anchor`, `resolve-paragraph-anchor`, `list-paragraph-anchors`, `get-paragraph-anchor`, `prune-paragraph-anchors`, `get-note-structure`, `list-note-links`, `list-native-tags`, `update-note`, `append-to-note`, `insert-link`, `delete-note`, `move-note`, `list-notes`, `get-selected-notes`, `list-folders`, `list-smart-folders`, `create-folder`, `delete-folder`, `list-accounts`, `get-default-location`, `list-shared-notes`, `get-sync-status`, `health-check`, `doctor`, `get-notes-stats`, `list-attachments`, `batch-delete-notes`, `batch-move-notes`, `save-attachment`, `list-paper-attachments`, `export-paper-image`, `export-attachments`, `fetch-attachment`, `show-attachment`, `export-notes-json`, `get-note-markdown`, `export-notes-markdown`, `export-notes-html`, `get-checklist-state`, `get-audio-transcripts`, `get-note-metadata`, `list-special-notes`, `get-note-drawings`, `transcribe-note-audio`, `list-recent-notes`, `list-folder-tree`, `get-folder-by-id`, `rename-folder`, `add-attachment`, `create-note-with-attachment`, `add-attachment-from-pasteboard`, `delete-folder-by-id`, `list-markdown-templates`, `show-markdown-template`, `validate-markdown-template`, `save-markdown-template`, `delete-markdown-template`, `get-capabilities`, `append-native`, `create-checklist-item`, `create-checklist-items`, `create-table`, `set-note-pinned`, `remove-native-tags`, `replace-native-tag`, `insert-note-link`, `native-tags-status`, `add-native-tags`, `native-helper-status`, `native-note-state`, `native-checklist-state`, `analyze-svg`.

89 tool registrations. `find-note`, `weekly-review`, `new-meeting-note` are prompts, not tools. Unavailable actions in nativeOperations.ts are not registrations. The private helper is read-only.

### danielhopkins/apple-tools

[README][apple-126] · [notes/apple-notes][apple] · commit `e946c9e98330`.
Other definitions: [notes/mergeable.py][apple-78]; [notes/notestore.py][apple-127].

CLI: `apple-notes` / `apple notes`: `search`, `folders`, `export`, `recordings`, `transcript`, `summary`, `get-url`, `create`, `append`, `delete`, `install-shortcuts`, `status`.

MCP: none.

The inspected Notes executable is Python, not Swift. Only its Notes component is included.

### coddingtonbear/icloud-md

[README][cloud-128] · [src/cli.ts][cloud] · commit `ffa20ef6378a`.
Other definitions: [src/notes/tableEdit.ts][cloud-57].

CLI: `icloud-md`: `install-browser`, `clone`, `pull`, `push`, `status`, `restore`, `delete`, `object list/show/delete`, `history`, `diff`, `revert`, `bug-report`, `reauthenticate`, `verify-auth`.

MCP: none.

Only features relevant to Mac Notes/Markdown workflows are counted; browser login supplies CloudKit web credentials. No local macOS DB/AppleScript backend.

### threeplanetssoftware/apple_cloud_notes_parser

[README][parser-129] · [notes_cloud_ripper.rb][parser] · commit `4754a2b62686`.
Other definitions: [lib/AppleNotesEmbeddedObject.rb][parser-111]; [lib/AppleUniformTypeIdentifier.rb][parser-95].

CLI: `ruby notes_cloud_ripper.rb`: `--itunes-dir/-i`, `--file/-f`, `--physical/-p`, `--mac/-m`; `--output-dir/-o`, `--one-output-folder/-g`, `--password-file/-w`, `--manual-password`, `--show-password-successes`, `--retain-display-order/-r`, `--range-start`, `--range-end`, `--individual-files`, `--uuid`, `--help/-h`. No subcommands.

MCP: none.

### dogsheep/apple-notes-to-sqlite

[README][dog-130] · [apple_notes_to_sqlite/cli.py][dog] · commit `e55a802d37a8`.

CLI: `apple-notes-to-sqlite DB_PATH` (also `python -m apple_notes_to_sqlite`); `--dump`, `--schema`, `--stop-after`. No subcommands.

MCP: none.

Reads through AppleScript; SQLite is the export destination.

### mattjefferson/honeycrisp

[README][honey-131] · [Sources/honeycrisp/CLI/Main.swift][honey] · commit `e30335247068`.

CLI: `honeycrisp`: `list` (`--accounts`, `--folders`), `search`, `show`, `add`, `update`, `append`, `delete`, `export`, `version`.

MCP: none.

### paradise-runner/cider

[README][cider-132] · [internal/cli/root.go][cider] · commit `eefb4f6ccbf5`.
Other definitions: [internal/cli/push.go][cider-133]; [internal/cli/pull.go][cider-134]; [internal/cli/diff.go][cider-135]; [internal/cli/files.go][cider-70].

CLI: `cider`: `push`, `pull`, `diff`, `completion bash/zsh/fish/powershell`, `help`; `--version`. Push/pull accept files or directories.

MCP: none.

### biao29/notesctl

[README][biao-136] · [Sources/notesctl/CommandRouter.swift][biao] · commit `d5a2e43b040b`.

CLI: `notesctl`: `list`/`ls`, `show`/`cat`/`get`, `search`/`find`, `add`/`new`/`create`, `edit`/`append`, `move`/`mv`, `delete`/`rm`, `folders` (`--create`, `--delete`), `status`, `help`; `--version`.

MCP: none.

### FradSer/note

[README][frad-137] · [Sources/note/Commands/NoteCommands.swift][frad] · commit `5c8e283f7d33`.
Other definitions: [Sources/note/Commands/FolderCommands.swift][frad-138]; [Sources/note/Commands/SyncCommands.swift][frad-139]; [Sources/note/Commands/SyncDirectCommands.swift][frad-140]; [Sources/note/Commands/PreferencesCommand.swift][frad-141]; [Sources/NoteCommands/SharedSyncCommands.swift][frad-71]; [Sources/NoteCommands/SyncDaemonCommands.swift][frad-142].

CLI: `note notes list/show/create/edit/move/search/delete`; `folders list/create/delete`; `sync` (default run), `sync run/push/pull/config/status`; `sync exclude list/add/remove`; `sync daemon install/uninstall/status` (Mac); `sync notes list/show/create/delete`; `sync folders list/create/delete`; `prefs list/add/remove/get`.

MCP: none.

### angelespejo/apple-notes-cli

[README][angel-143] · [src/main.sh][angel] · commit `9e29fd74a64b`.

CLI: `apple-notes-cli`: `open [NOTE]`, `open-new`, `add`, `rm`, `exists`, `add-folder`, `rm-folder [--only-notes]`.

MCP: none.

`exists-folder` is documented and implemented as a function, but absent from the command dispatcher; not counted as callable.

### RafalWilinski/mcp-apple-notes

[README][raf-144] · [index.ts][raf] · commit `b95a40ae858d`.

CLI: Server startup only; no Notes CRUD subcommands.

MCP: `list-notes`, `index-notes`, `get-note`, `search-notes`, `create-note`.

### Kylmakalle/apple-notes-exporter

[README][kyl-145] · [Makefile][kyl] · commit `1d1b727ccbaa`.
Other definitions: [scripts/organize.py][kyl-146]; [scripts/patch_image_paths.py][kyl-147].

CLI: `make` / `make all`, `save`, `organize`, `patch_image_paths`, `clean`; Shortcut `Export Notes`; `scripts/organize.py TARGET`, `scripts/patch_image_paths.py DIRECTORY`.

MCP: none.

Shortcut is the exporter; Make/Python organize its output. Titles only for locked notes; drawings are unsupported.

### sirmews/apple-notes-mcp

[README][sir-148] · [src/apple_notes_mcp/server.py][sir] · commit `d4cfb110b814`.
Other definitions: [src/apple_notes_mcp/notes_database.py][sir-40].

CLI: `apple-notes-mcp` server startup (`--db-path`).

MCP: `get-all-notes`, `read-note`, `search-notes`.

`find-note` is a prompt. Also exposes note resources. SQL body search uses LIKE on compressed ZDATA.

### krasun/notes-mcp

[README][kras-149] · [src/mcp.ts][kras] · commit `41b8a440f560`.

CLI: Server startup only; no Notes CRUD subcommands.

MCP: `notes-create-note`, `notes-get-folders`, `notes-get-notes`, `notes-get-note-by-id`, `notes-get-note-by-title`, `notes-note-count`.

README uses `notes-get-note-count`; the registered name is `notes-note-count`.

### henilcalagiya/mcp-apple-notes

[README][hen-150] · [mcp_apple_notes/server.py][hen] · commit `ca9df02bbb83`.

CLI: `mcp-apple-notes` server startup.

MCP: `create_note`, `create_folder`, `read_note`, `read_folder`, `update_note`, `rename_folder`, `move_folder`, `list_folder_with_structure`, `delete_note`, `delete_folder`, `list_notes_with_structure`, `list_all_notes`, `move_note`, `search_notes`.

### RodriguesJohn/applenotesmcp

[README][rod-151] · [src/index.ts][rod] · commit `109b863c34e0`.

CLI: Server startup only.

MCP: `list_folders`, `list_notes`, `get_note`, `get_note_by_id`, `create_note`, `search_notes`, `update_note`, `delete_note`.

### Siddhant-K-code/mcp-apple-notes

[README][sid-152] · [src/index.ts][sid] · commit `539fd1858192`.

CLI: Server startup only.

MCP: `create-note`, `search-notes`, `get-note-content`.

create-note tags are returned as metadata; source does not create native tags.

### ailenshen/apple-notes-mcp

[README][ail-153] · [Sources/AppleNotesMCP/MCP/WriteTools.swift][ail] · commit `a7da277adacc`.
Other definitions: [Sources/AppleNotesMCP/main.swift][ail-154]; [Sources/AppleNotesMCP/MCP/ReadTools.swift][ail-155]; [Sources/AppleNotesMCP/MCP/AttachmentTool.swift][ail-156].

CLI: `apple-notes-mcp`: `--stdio`, `--onboarding`/`setup`, `--self-check`; no CRUD CLI.

MCP: `overview`, `search`, `read_note`, `describe_note`, `create_note`, `edit_note`, `delete_note`, `move_note`, `manage_folder`, `read_attachment`.

manage_folder actions: create/rename/delete/export. move_note also restores trash. Attachment content can be read/preserved, not added/removed.

### Dan8Oren/mcp-apple-notes

[README][dan-157] · [index.ts][dan] · commit `6917c2df2e22`.

CLI: Server startup only.

MCP: `index-notes`, `list-folders`, `list-notes`, `search-notes`, `get-note`, `create-note`, `edit-note`, `append-to-note`, `move-note`, `delete-note`.

Read-only environment mode hides mutations.

### mcolyer/mcp-apple-notes-py

[README][mcol-158] · [main.py][mcol] · commit `9e730ebd629c`.

CLI: Python/uv server startup only.

MCP: `list_notes`, `get_notes`, `search_notes`, `create_note`.

Uses macnotesapp; get_notes accepts multiple IDs.

### disco-trooper/apple-notes-mcp

[README][disco-159] · [src/server.ts][disco] · commit `58ba7c68d409`.
Other definitions: [src/notes/crud.ts][disco-56]; [src/graph/extract.ts][disco-46]; [src/search/chunk-search.ts][disco-44].

CLI: `apple-notes-mcp` server; `apple-notes-mcp-setup` interactive setup.

MCP: `search-notes`, `index-notes`, `start-index-job`, `get-index-job`, `list-index-jobs`, `cancel-index-job`, `reindex-note`, `purge-index`, `list-notes`, `get-note`, `get-tables`, `list-folders`, `list-tags`, `search-by-tag`, `related-notes`, `export-graph`, `create-note`, `update-note`, `delete-note`, `move-note`, `edit-table`, `batch-delete`, `batch-move`.

Read-only mode hides mutations. edit-table writes the entire HTML body after a date/body comparison.

### shakedlokits/stash

[README][stash-160] · [src/bashly.yml][stash] · commit `e083a2ec5c89`.

CLI: `stash`: `push`, `pull`, `diff`, `completions`; help/version flags.

MCP: none.

### shareup/nanotes

[README][nano-161] · [main.ts][nano] · commit `0b0434f6659a`.
Other definitions: [commands/dump.ts][nano-72].

CLI: `nanotes`: `folders`, `list`, `recent`, `today`, `show`, `search`, `attachments`, `dump`, `create`.

MCP: none.

### honeybluesky/my-apple-remembers

[README][memory-162] · [src/mcp_my_apple_remembers/server.py][memory] · commit `41c77788da6a`.

CLI: Server startup only.

MCP: `my_apple_recall_memory`, `my_apple_save_memory`.

Accepts AppleScript and runs it over SSH; no fixed Notes operation inventory beyond these two tools.

### Tom-Semple/mcp-apple-notes-fixed

[README][tom-163] · [index.ts][tom] · commit `1f51ac195a99`.

CLI: Server startup only; no Notes CRUD subcommands.

MCP: `list-notes`, `index-notes`, `get-note`, `search-notes`, `create-note`.

### RhetTbull/macnotesapp

[README][mac-38] · [macnotesapp/cli/cli.py][mac] · commit `acef174ea105`.

CLI: `macnotesapp` / `notes`: `accounts`, `add`, `append`, `cat`, `config`, `delete`, `dump`, `edit`, `help`, `list`, `mkdir`, `move`, `rename`, `rmdir`.

MCP: none.

### RhetTbull/apple-notes-parser

[README][rparser-164] · [src/apple_notes_parser/cli.py][rparser] · commit `635efa0fb481`.
Other definitions: [src/apple_notes_parser/embedded_objects.py][rparser-81]; [src/apple_notes_parser/protobuf_parser.py][rparser-84].

CLI: `apple-notes-parser`: `list`, `search`, `export`, `stats`, `attachments`, `tags`.

MCP: none.

### dunhamsteve/notesutils

[README][utils-165] · [notes2html][utils] · commit `582e569c9d0a`.
Other definitions: [notes2bear][utils-166]; [notes2quiver][utils-167].

CLI: `notes2html [--svg] [--title] DEST`, `notes2bear`, `notes2quiver [DEST]`.

MCP: none.

No checked-in notes2md command; do not infer it from issue references.

### storizzi/notes-exporter

[README][storiz-66] · [exportnotes.zsh][storiz] · commit `ca6149232d0e`.
Other definitions: [notes_service/cli.py][storiz-69]; [qdrant_integration.py][storiz-168]; [sync_to_notes.py][storiz-169]; [reconcile.py][storiz-170]; [tracker_io.py][storiz-171]; [notes_db.py][storiz-172]; [events.py][storiz-173]; [setup_launchd.py][storiz-174]; [notes_permission.py][storiz-175].

CLI: `exportnotes.zsh` default export; modes `--query`, `--sync`, `--sync-only`, `--sync-dry-run`, `--create-new`, `--update-qdrant`. `notes-exporter serve`; `user add/list/passwd/remove`; `apikey create/list/revoke`; `permission status/request`; `service install/uninstall/status`. `qdrant_integration.py sync/status/check/search/reset/dry-run`. Standalone scripts: `build_manifest.py`, `query_notes.py`, `convert_to_pdf.py`, `reorganize_by_folder.py`, `setup_launchd.py` (default setup; `--remove`, `--load`, `--unload`, `--test`, `--status`, `--debug`), `notes_db.py tags`, `events.py emit/relay`, `extract_images.py`, `convert_to_markdown.py`, `notes_permission.py [--ask]`, `convert_to_epub.py`, `prune_deleted.py`, `build_epub_books.py`, `convert_to_word.py`, `tracker_io.py load/save/finalize`, `reconcile.py`, `sync_to_notes.py`, `set_file_dates.py`.

MCP: none.

Inspected HEAD documents 1.5.0 as unreleased; these are source capabilities, not verified released behavior. HTTP routes are not MCP tools.

### alexwlchan/notes-export

[README][alex-176] · [notes-export.scpt][alex] · commit `fc5194e79141`.

CLI: `osascript notes-export.scpt`; interactive folder picker, no subcommands.

MCP: none.

### mattrose/AppleNotes2Joplin

[README][joplin-177] · [AppleNotes2Joplin.applescript][joplin] · commit `2540c4d6fbeb`.

CLI: `osascript AppleNotes2Joplin.applescript`; interactive Joplin/Notes UI, no subcommands.

MCP: none.

### mattt/iMCP

[README][imcp-178] · [App/Services/Notes.swift][imcp] · commit `c30e84cef24e`.

CLI: App / `imcp-server` stdio startup; no Notes CRUD CLI.

MCP: `notes_folders`, `notes_fetch`, `notes_read`.

Only Notes tools; calendar, contacts and other iMCP services excluded. notes_fetch provides search/filtering.

### xiaofeng-han/apple-mcp

[README][xiao-179] · [Sources/NotesComponent/Routes.swift][xiao] · commit `3b18d907ca5b`.
Other definitions: [Sources/AppCore/CLI/Commands.swift][xiao-180]; [Sources/NotesComponent/Tools/ReadTools.swift][xiao-82]; [Sources/NotesComponent/Tools/WriteTools.swift][xiao-58]; [Sources/NotesComponent/Tools/AttachmentTool.swift][xiao-80].

CLI: `apple-notes-mcp`: `notes list`, `notes search`, `notes read`, `notes create`, `notes copy`, `notes edit`, `notes delete`, `notes move`, `notes describe`, `tags rename`, `tags delete`, `attachments read`, `folders list`, `folders create`, `folders rename`, `folders move`, `folders delete`, `folders export`; `call TOOL [JSON|-]`, `setup`, `skill`, `agents list/set-up/install`, `help`; `--stdio`, `--settings`, `--self-check`, `--version`.

MCP: `overview`, `search`, `read_note`, `read_attachment`, `describe_note`, `create_note`, `edit_note`, `move_note`, `delete_note`, `manage_folder`, `manage_tag`.

manage_folder actions: create/rename/move/delete/export; create with tags makes a Smart Folder. manage_tag: rename/delete. notes move restores Recently Deleted. Other app components excluded.

## 3. Stored content types and decoders

UTIs select attachment types; checklists, rich runs, OCR and transcript classes use other fields. “Export” below means copying an original/fallback asset, not decoding its internal format. The list covers types handled by these sources; Apple can add others.

| Content type / representation | Tools | Decoding and limits; evidence |
| --- | --- | --- |
| Body protobuf; rich runs and paragraphs (not a UTI) | [threeplanetssoftware/apple_cloud_notes_parser][parser]; [sweetrb/apple-notes-mcp][sweet]; [johnmatthewtennant/notekit-cli][mk]; [coddingtonbear/icloud-md][cloud]; [danielhopkins/apple-tools][apple]; [RhetTbull/apple-notes-parser][rparser]; [shareup/nanotes][nano]; [ailenshen/apple-notes-mcp][ail]; [xiaofeng-han/apple-mcp][xiao] | gzip NoteStoreProto contains UTF-16 text/runs. Tables and media require separate records; extracting note_text alone is not rich decoding. [proto/notestore.proto][parser-83]; [src/apple_notes_parser/protobuf_parser.py][rparser-84]; [src/utils/noteRichText.ts][sweet-85] |
| Checklist (paragraph todo UUID/done fields; not a UTI) | [threeplanetssoftware/apple_cloud_notes_parser][parser]; [sweetrb/apple-notes-mcp][sweet]; [johnmatthewtennant/notekit-cli][mk]; [coddingtonbear/icloud-md][cloud]; [ailenshen/apple-notes-mcp][ail]; [xiaofeng-han/apple-mcp][xiao] | Decode identity, checked state, indentation and order; HTML checkbox-looking text is insufficient. [lib/ProtoPatches.rb][parser-86]; [Sources/NoteModel/Checklist.swift][xiao-55] |
| `com.apple.notes.table` | [threeplanetssoftware/apple_cloud_notes_parser][parser]; [sweetrb/apple-notes-mcp][sweet]; [coddingtonbear/icloud-md][cloud]; [danielhopkins/apple-tools][apple]; [ailenshen/apple-notes-mcp][ail]; [xiaofeng-han/apple-mcp][xiao]; [dunhamsteve/notesutils][utils]; [mattt/iMCP][imcp] | Ordered CRDT row/column identities and rich cell bodies. Ruby reconstructs HTML/JSON; native readers access NotesShared tables. [lib/AppleNotesEmbeddedTable.rb][parser-87]; [src/utils/noteTables.ts][sweet-88]; [src/notes/tableEdit.ts][cloud-57]; [Sources/NotesKit/NotesShared/TableEditor.swift][ail-89] |
| `com.apple.notes.gallery` | [threeplanetssoftware/apple_cloud_notes_parser][parser]; [sweetrb/apple-notes-mcp][sweet]; [ailenshen/apple-notes-mcp][ail]; [xiaofeng-han/apple-mcp][xiao] | Ruby decodes CRDT child order. xiaofeng/ailenshen sort children by creation date, which may differ from page order; gallery is not a single file. [lib/AppleNotesEmbeddedGallery.rb][parser-90]; [src/utils/attachmentAssets.ts][sweet-91]; [Sources/NotesComponent/Store/Attachments.swift][xiao-92] |
| `com.apple.drawing`, `com.apple.drawing.2` | [threeplanetssoftware/apple_cloud_notes_parser][parser]; [sweetrb/apple-notes-mcp][sweet]; [dunhamsteve/notesutils][utils] | Ruby exports fallback raster. sweetrb decodes supported PencilKit strokes to SVG; notesutils has legacy SVG output. These are not modern Paper editing support. [lib/AppleNotesEmbeddedDrawing.rb][parser-93]; [src/utils/noteDrawings.ts][sweet-75]; [notes2html][utils] |
| `com.apple.paper` | [threeplanetssoftware/apple_cloud_notes_parser][parser]; [sweetrb/apple-notes-mcp][sweet]; [ailenshen/apple-notes-mcp][ail]; [xiaofeng-han/apple-mcp][xiao] | Modern drawing: fallback image generations/handwriting text, not full editable vector stroke decoding. [lib/AppleNotesEmbeddedDrawing.rb][parser-93]; [src/utils/paperAttachments.ts][sweet-94]; [Sources/NotesComponent/Store/Attachments.swift][xiao-92] |
| `com.apple.notes.sketch` | [threeplanetssoftware/apple_cloud_notes_parser][parser] | Classified as an image and exported through the image-attachment class; no dedicated stroke decoder. [lib/AppleUniformTypeIdentifier.rb][parser-95]; [lib/AppleNotesEmbeddedPublicJpeg.rb][parser-96] |
| `com.apple.paper.doc.scan`, `com.apple.paper.doc.pdf` | [threeplanetssoftware/apple_cloud_notes_parser][parser]; [sweetrb/apple-notes-mcp][sweet]; [ailenshen/apple-notes-mcp][ail]; [xiaofeng-han/apple-mcp][xiao] | Cached scan PDF/page assets; Ruby exports fallback PDF, not OCR or markup semantics. [lib/AppleNotesEmbeddedPaperDocScan.rb][parser-97]; [src/utils/attachmentAssets.ts][sweet-91] |
| `public.jpeg`, `public.png`, `public.heic`, `public.tiff`, `public.svg-image`, `com.compuserve.gif`, `org.webmproject.webp` | [threeplanetssoftware/apple_cloud_notes_parser][parser]; [sweetrb/apple-notes-mcp][sweet]; [coddingtonbear/icloud-md][cloud]; [ailenshen/apple-notes-mcp][ail]; [xiaofeng-han/apple-mcp][xiao] | Original asset copying differs from image decoding. Native tools make previews through ImageIO; Ruby dispatches recognized image UTIs to its image class. [lib/AppleUniformTypeIdentifier.rb][parser-95]; [lib/AppleNotesEmbeddedPublicJpeg.rb][parser-96]; [Sources/NotesComponent/Tools/AttachmentTool.swift][xiao-80] |
| `com.adobe.pdf` | [threeplanetssoftware/apple_cloud_notes_parser][parser]; [sweetrb/apple-notes-mcp][sweet]; [cardmagic/notes][card]; [ailenshen/apple-notes-mcp][ail]; [xiaofeng-han/apple-mcp][xiao] | Export original; cardmagic extracts cached PDF text via pdftotext; native tools use PDFKit for text/previews. [lib/AppleNotesEmbeddedPDF.rb][parser-98]; [src/attachments.ts][card-73]; [Sources/NotesComponent/Tools/AttachmentTool.swift][xiao-80] |
| `public.url` (URL preview card) | [threeplanetssoftware/apple_cloud_notes_parser][parser]; [sweetrb/apple-notes-mcp][sweet]; [ailenshen/apple-notes-mcp][ail]; [xiaofeng-han/apple-mcp][xiao] | URL/title/preview asset. Separate from ordinary hyperlink attributes and native note links. [lib/AppleNotesEmbeddedPublicURL.rb][parser-99]; [src/utils/attachmentAssets.ts][sweet-91] |
| `public.vcard` | [threeplanetssoftware/apple_cloud_notes_parser][parser] | Contact attachment exported as file/link; not a claim that all vCard fields are parsed. [lib/AppleNotesEmbeddedPublicVCard.rb][parser-100] |
| `com.apple.ical.ics` | [threeplanetssoftware/apple_cloud_notes_parser][parser] | Calendar file/link export; not a calendar-event semantic decoder. [lib/AppleNotesEmbeddedCalendar.rb][parser-101] |
| `com.apple.m4a-audio`, `public.mpeg-4-audio`, `public.mp3`, WAV/AIFF audio UTIs | [threeplanetssoftware/apple_cloud_notes_parser][parser]; [sweetrb/apple-notes-mcp][sweet]; [coddingtonbear/icloud-md][cloud]; [ailenshen/apple-notes-mcp][ail]; [xiaofeng-han/apple-mcp][xiao] | Ruby exports audio files only. sweetrb/native tools resolve recording fragments; transcript lives separately. [lib/AppleNotesEmbeddedPublicAudio.rb][parser-102]; [lib/AppleUniformTypeIdentifier.rb][parser-95]; [src/utils/noteAudio.ts][sweet-103] |
| `public.mpeg-4`, `com.apple.quicktime-movie` and other video UTIs | [threeplanetssoftware/apple_cloud_notes_parser][parser]; [sweetrb/apple-notes-mcp][sweet]; [ailenshen/apple-notes-mcp][ail]; [xiaofeng-han/apple-mcp][xiao] | Original media; native MCP tools can return a representative video frame. [lib/AppleNotesEmbeddedPublicVideo.rb][parser-104]; [Sources/NotesComponent/Tools/AttachmentTool.swift][xiao-80] |
| `com.apple.notes.inlinetextattachment.hashtag` | [threeplanetssoftware/apple_cloud_notes_parser][parser]; [RhetTbull/apple-notes-parser][rparser]; [sweetrb/apple-notes-mcp][sweet]; [xiaofeng-han/apple-mcp][xiao] | Alt text plus native tag identity; regex #word extraction is a weaker fallback. [lib/AppleNotesEmbeddedInlineHashtag.rb][parser-105]; [src/apple_notes_parser/embedded_objects.py][rparser-81]; [src/utils/noteRichText.ts][sweet-85] |
| `com.apple.notes.inlinetextattachment.mention` | [threeplanetssoftware/apple_cloud_notes_parser][parser]; [RhetTbull/apple-notes-parser][rparser]; [sweetrb/apple-notes-mcp][sweet]; [xiaofeng-han/apple-mcp][xiao] | Mention alt text/token identity; does not imply an API to notify or add participants. [lib/AppleNotesEmbeddedInlineMention.rb][parser-106]; [src/apple_notes_parser/embedded_objects.py][rparser-81] |
| `com.apple.notes.inlinetextattachment.link` | [threeplanetssoftware/apple_cloud_notes_parser][parser]; [RhetTbull/apple-notes-parser][rparser]; [sweetrb/apple-notes-mcp][sweet]; [johnmatthewtennant/notekit-cli][mk]; [xiaofeng-han/apple-mcp][xiao] | Native note reference, target UUID and label; do not flatten to a web URL and lose the target. [lib/AppleNotesEmbeddedInlineLink.rb][parser-107]; [src/apple_notes_parser/embedded_objects.py][rparser-81]; [src/utils/noteRichText.ts][sweet-85] |
| `com.apple.notes.inlinetextattachment.calculateresult` | [threeplanetssoftware/apple_cloud_notes_parser][parser]; [xiaofeng-han/apple-mcp][xiao] | Stored result/alt text, not recomputation. [lib/AppleNotesEmbeddedInlineCalculateResult.rb][parser-108]; [Sources/NotesComponent/Store/BodyReader.swift][xiao-109] |
| `com.apple.notes.inlinetextattachment.calculategraphexpression` | [threeplanetssoftware/apple_cloud_notes_parser][parser]; [xiaofeng-han/apple-mcp][xiao] | Stored expression text/metadata, not a full graph renderer. [lib/AppleNotesEmbeddedInlineCalculateGraphExpression.rb][parser-110]; [Sources/NotesComponent/Store/BodyReader.swift][xiao-109] |
| `com.apple.notes.inlinetextattachment.dividerline` | [xiaofeng-han/apple-mcp][xiao] | Native divider handling; Ruby falls back to a generic inline object. [Sources/NotesComponent/Store/BodyReader.swift][xiao-109]; [lib/AppleNotesEmbeddedObject.rb][parser-111] |
| Office/iWork/RTFD/EPUB/Markdown/document UTIs; generic `public.*`, `dyn.*`, `com.apple.macbinary-archive` | [threeplanetssoftware/apple_cloud_notes_parser][parser]; [sweetrb/apple-notes-mcp][sweet]; [coddingtonbear/icloud-md][cloud]; [ailenshen/apple-notes-mcp][ail]; [xiaofeng-han/apple-mcp][xiao] | File/thumbnail export or placeholder; not semantic decoding of every document format. See Ruby UTI allowlists/dispatch. [lib/AppleUniformTypeIdentifier.rb][parser-95]; [lib/AppleNotesEmbeddedDocument.rb][parser-112]; [lib/AppleNotesEmbeddedPublicObject.rb][parser-113]; [lib/AppleNotesEmbeddedObject.rb][parser-111] |
| Ordinary external hyperlink (run attribute, not inline-note-link UTI) | [threeplanetssoftware/apple_cloud_notes_parser][parser]; [sweetrb/apple-notes-mcp][sweet]; [johnmatthewtennant/notekit-cli][mk]; [coddingtonbear/icloud-md][cloud]; [ailenshen/apple-notes-mcp][ail]; [xiaofeng-han/apple-mcp][xiao] | URL stored on a character range; preserve alongside paragraph formatting. [proto/notestore.proto][parser-83]; [src/utils/noteRichText.ts][sweet-85] |
| OCR, handwriting, image classification (attachment properties, not UTIs) | [sweetrb/apple-notes-mcp][sweet]; [ailenshen/apple-notes-mcp][ail]; [xiaofeng-han/apple-mcp][xiao] | Stored recognition may be absent. Ruby parser does not decode OCR; copying a scan PDF is not OCR support. [src/utils/paperAttachments.ts][sweet-94]; [Sources/NotesKit/NotesShared/Attachments.swift][ail-114]; [Sources/NotesComponent/Store/Search.swift][xiao-74] |
| Audio recording/transcript CRDT classes (not UTIs): `com.apple.notes.ICTTAudioRecording`, recording fragments, `ICTTTranscriptSegment` | [sweetrb/apple-notes-mcp][sweet]; [danielhopkins/apple-tools][apple]; [xiaofeng-han/apple-mcp][xiao] | sweetrb/apple-tools decode segments/timing; xiaofeng returns native flattened text/summaries. Separate from body runs. Ruby audio export has no transcript decoder. [src/utils/audioTranscripts.ts][sweet-77]; [notes/mergeable.py][apple-78]; [Sources/NotesComponent/Store/Attachments.swift][xiao-92] |
| Unknown/unavailable/deleted attachment records | [threeplanetssoftware/apple_cloud_notes_parser][parser]; [shareup/nanotes][nano]; [sweetrb/apple-notes-mcp][sweet]; [xiaofeng-han/apple-mcp][xiao] | Expose type/ID and missing-content status. Generic metadata/placeholder is not a decoder; avoid silently dropping the marker. [lib/AppleNotesEmbeddedObject.rb][parser-111]; [commands/dump.ts][nano-72]; [src/utils/attachmentAssets.ts][sweet-91] |

## 4. Gaps nobody fills

No complete implementation found in the inspected revisions:

- Full-fidelity two-way Markdown sync across all rich objects, attachment uploads, locked/shared notes and unknown future types. icloud-md makes non-table attachments and asset-backed bodies read-only; other sync tools have narrower preservation/merge guarantees ([README.md][cloud-128]; [notekit-handwritten.m][mk-47]).
- Modern Paper vector editing, scan markup and native audio recording creation through a background interface. Fallback image export and external transcription do not fill this ([src/tools/nativeOperations.ts][sweet-54]; [src/utils/noteDrawings.ts][sweet-75]).
- Sharing invitation/permission lifecycle and authenticated lock/unlock. Shared-note edits and legacy backup password decryption are narrower ([src/tools/nativeOperations.ts][sweet-54]; [lib/AppleDecrypter.rb][parser-50]).
- Durable exactly-once write recovery across process crashes/timeouts. Revision checks and post-write verification reduce uncertainty, but no inspected command contract provides a persistent idempotency key and replay result ([src/tools/nativeOperations.ts][sweet-54]; [Sources/NotesComponent/Tools/WriteTools.swift][xiao-58]).

[memo]: https://github.com/antoniorodr/memo/blob/1cf73cd47dff7a7d35f3a1dc51be483bcb8b65a2/src/memo/memo.py
[mk]: https://github.com/johnmatthewtennant/notekit-cli/blob/dcfdb5b25b8932d98cc66d625e71a69d80e9ad70/notekit.m
[javi]: https://github.com/JaviSoto/apple-notes-cli/blob/aabdb456ab749f40eab352c6884a26df6d1b075f/src/cli.rs
[xwmx]: https://github.com/xwmx/notes-app-cli/blob/422798ace09ca97bd6009b91b90c1795b8208b12/notes-app
[card]: https://github.com/cardmagic/notes/blob/7445e3f3f13feeab506d0bf45866d6a0fc9dea29/src/cli.ts
[sweet]: https://github.com/sweetrb/apple-notes-mcp/blob/3dbf1538cedf5dd289f14dd11bcd202b70ed869f/src/index.ts
[apple]: https://github.com/danielhopkins/apple-tools/blob/e946c9e98330cd438418154145ef8b312a0f8e80/notes/apple-notes
[cloud]: https://github.com/coddingtonbear/icloud-md/blob/ffa20ef6378a453f0935d26f03acedf3e58540f2/src/cli.ts
[parser]: https://github.com/threeplanetssoftware/apple_cloud_notes_parser/blob/4754a2b62686570cca46690d101079e80cf6ae66/notes_cloud_ripper.rb
[dog]: https://github.com/dogsheep/apple-notes-to-sqlite/blob/e55a802d37a896475b6cf475c1ba947af63cca73/apple_notes_to_sqlite/cli.py
[honey]: https://github.com/mattjefferson/honeycrisp/blob/e303352470683896c2802f46b0d1629779f60c29/Sources/honeycrisp/CLI/Main.swift
[cider]: https://github.com/paradise-runner/cider/blob/eefb4f6ccbf54c2bbefdf4854014dd4c3771aa90/internal/cli/root.go
[biao]: https://github.com/biao29/notesctl/blob/d5a2e43b040b5e3d214a409366a740416ed4b70e/Sources/notesctl/CommandRouter.swift
[frad]: https://github.com/FradSer/note/blob/5c8e283f7d332d6b97ccdccd633c2148fc0f894f/Sources/note/Commands/NoteCommands.swift
[angel]: https://github.com/angelespejo/apple-notes-cli/blob/9e29fd74a64b663feb760e1431184e47664bacfb/src/main.sh
[raf]: https://github.com/RafalWilinski/mcp-apple-notes/blob/b95a40ae858d791cd54e2a52700041bb2728fbe6/index.ts
[kyl]: https://github.com/Kylmakalle/apple-notes-exporter/blob/1d1b727ccbaaa1c98f846a2c2d21f851cc4b276a/Makefile
[sir]: https://github.com/sirmews/apple-notes-mcp/blob/d4cfb110b8141bf16d7db08b8573e54192cf4873/src/apple_notes_mcp/server.py
[kras]: https://github.com/krasun/notes-mcp/blob/41b8a440f560da891e03aa65728e9636b6916d11/src/mcp.ts
[hen]: https://github.com/henilcalagiya/mcp-apple-notes/blob/ca9df02bbb83757b58880f5f2d82afa4c8777656/mcp_apple_notes/server.py
[rod]: https://github.com/RodriguesJohn/applenotesmcp/blob/109b863c34e001b50e17911d0d797964cc701ccd/src/index.ts
[sid]: https://github.com/Siddhant-K-code/mcp-apple-notes/blob/539fd1858192e4038fc49a21bd30bd610cc47c1b/src/index.ts
[ail]: https://github.com/ailenshen/apple-notes-mcp/blob/a7da277adacc5684114ab7038e0483b6e6aa7624/Sources/AppleNotesMCP/MCP/WriteTools.swift
[dan]: https://github.com/Dan8Oren/mcp-apple-notes/blob/6917c2df2e2217fd16c4889697a2658a498b230d/index.ts
[mcol]: https://github.com/mcolyer/mcp-apple-notes-py/blob/9e730ebd629cd9b3a276de18410bc7982ecf1587/main.py
[disco]: https://github.com/disco-trooper/apple-notes-mcp/blob/58ba7c68d40994e37d02ceb6db10a10ab1ddcf81/src/server.ts
[stash]: https://github.com/shakedlokits/stash/blob/e083a2ec5c89508b211db3e9865c7ee5efb19977/src/bashly.yml
[nano]: https://github.com/shareup/nanotes/blob/0b0434f6659a076cfdbb612c45d41f077b0dbb32/main.ts
[memory]: https://github.com/honeybluesky/my-apple-remembers/blob/41c77788da6a76c07532b49a4e99b5b70ffeb984/src/mcp_my_apple_remembers/server.py
[tom]: https://github.com/Tom-Semple/mcp-apple-notes-fixed/blob/1f51ac195a9902d6405b6017f8666a38db598847/index.ts
[mac]: https://github.com/RhetTbull/macnotesapp/blob/acef174ea1058c3b025a011690c665fe20c5a764/macnotesapp/cli/cli.py
[rparser]: https://github.com/RhetTbull/apple-notes-parser/blob/635efa0fb4813978eecc18a3b3bfcc2f04c80ba4/src/apple_notes_parser/cli.py
[utils]: https://github.com/dunhamsteve/notesutils/blob/582e569c9d0a6b398e91099260eaf761366a5f68/notes2html
[storiz]: https://github.com/storizzi/notes-exporter/blob/ca6149232d0ed37ed281b53a27b24c4e283b6b70/exportnotes.zsh
[alex]: https://github.com/alexwlchan/notes-export/blob/fc5194e79141ef37a9b3f69b5d2ff9cadd71fad8/notes-export.scpt
[joplin]: https://github.com/mattrose/AppleNotes2Joplin/blob/2540c4d6fbeb6972dfa61424be0e9ff86e84de10/AppleNotes2Joplin.applescript
[imcp]: https://github.com/mattt/iMCP/blob/c30e84cef24e2554ba5e128b1b8280e09586d5b4/App/Services/Notes.swift
[xiao]: https://github.com/xiaofeng-han/apple-mcp/blob/3b18d907ca5b36f4ed0c660783273fd1543b86c0/Sources/NotesComponent/Routes.swift
[mac-38]: https://github.com/RhetTbull/macnotesapp/blob/acef174ea1058c3b025a011690c665fe20c5a764/README.md
[sweet-39]: https://github.com/sweetrb/apple-notes-mcp/blob/3dbf1538cedf5dd289f14dd11bcd202b70ed869f/src/utils/noteQuery.ts
[sir-40]: https://github.com/sirmews/apple-notes-mcp/blob/d4cfb110b8141bf16d7db08b8573e54192cf4873/src/apple_notes_mcp/notes_database.py
[memo-41]: https://github.com/antoniorodr/memo/blob/1cf73cd47dff7a7d35f3a1dc51be483bcb8b65a2/src/memo_helpers/search_memo.py
[card-42]: https://github.com/cardmagic/notes/blob/7445e3f3f13feeab506d0bf45866d6a0fc9dea29/src/searcher.ts
[card-43]: https://github.com/cardmagic/notes/blob/7445e3f3f13feeab506d0bf45866d6a0fc9dea29/src/indexer.ts
[disco-44]: https://github.com/disco-trooper/apple-notes-mcp/blob/58ba7c68d40994e37d02ceb6db10a10ab1ddcf81/src/search/chunk-search.ts
[disco-45]: https://github.com/disco-trooper/apple-notes-mcp/blob/58ba7c68d40994e37d02ceb6db10a10ab1ddcf81/src/indexing/job-manager.ts
[disco-46]: https://github.com/disco-trooper/apple-notes-mcp/blob/58ba7c68d40994e37d02ceb6db10a10ab1ddcf81/src/graph/extract.ts
[mk-47]: https://github.com/johnmatthewtennant/notekit-cli/blob/dcfdb5b25b8932d98cc66d625e71a69d80e9ad70/notekit-handwritten.m
[sweet-48]: https://github.com/sweetrb/apple-notes-mcp/blob/3dbf1538cedf5dd289f14dd11bcd202b70ed869f/src/services/anchorRegistry.ts
[sweet-49]: https://github.com/sweetrb/apple-notes-mcp/blob/3dbf1538cedf5dd289f14dd11bcd202b70ed869f/src/utils/smartFolders.ts
[parser-50]: https://github.com/threeplanetssoftware/apple_cloud_notes_parser/blob/4754a2b62686570cca46690d101079e80cf6ae66/lib/AppleDecrypter.rb
[parser-51]: https://github.com/threeplanetssoftware/apple_cloud_notes_parser/blob/4754a2b62686570cca46690d101079e80cf6ae66/lib/AppleCloudKitShareParticipant.rb
[sweet-52]: https://github.com/sweetrb/apple-notes-mcp/blob/3dbf1538cedf5dd289f14dd11bcd202b70ed869f/src/utils/syncDetection.ts
[memo-53]: https://github.com/antoniorodr/memo/blob/1cf73cd47dff7a7d35f3a1dc51be483bcb8b65a2/src/memo_helpers/edit_memo.py
[sweet-54]: https://github.com/sweetrb/apple-notes-mcp/blob/3dbf1538cedf5dd289f14dd11bcd202b70ed869f/src/tools/nativeOperations.ts
[xiao-55]: https://github.com/xiaofeng-han/apple-mcp/blob/3b18d907ca5b36f4ed0c660783273fd1543b86c0/Sources/NoteModel/Checklist.swift
[disco-56]: https://github.com/disco-trooper/apple-notes-mcp/blob/58ba7c68d40994e37d02ceb6db10a10ab1ddcf81/src/notes/crud.ts
[cloud-57]: https://github.com/coddingtonbear/icloud-md/blob/ffa20ef6378a453f0935d26f03acedf3e58540f2/src/notes/tableEdit.ts
[xiao-58]: https://github.com/xiaofeng-han/apple-mcp/blob/3b18d907ca5b36f4ed0c660783273fd1543b86c0/Sources/NotesComponent/Tools/WriteTools.swift
[sweet-59]: https://github.com/sweetrb/apple-notes-mcp/blob/3dbf1538cedf5dd289f14dd11bcd202b70ed869f/src/services/linkInsert.ts
[sweet-60]: https://github.com/sweetrb/apple-notes-mcp/blob/3dbf1538cedf5dd289f14dd11bcd202b70ed869f/src/tools/directOperations.ts
[xiao-61]: https://github.com/xiaofeng-han/apple-mcp/blob/3b18d907ca5b36f4ed0c660783273fd1543b86c0/Sources/NotesComponent/Store/Writing.swift
[xiao-62]: https://github.com/xiaofeng-han/apple-mcp/blob/3b18d907ca5b36f4ed0c660783273fd1543b86c0/Sources/NotesComponent/Store/Organizer.swift
[mk-63]: https://github.com/johnmatthewtennant/notekit-cli/blob/dcfdb5b25b8932d98cc66d625e71a69d80e9ad70/notekit-generated.m
[xiao-64]: https://github.com/xiaofeng-han/apple-mcp/blob/3b18d907ca5b36f4ed0c660783273fd1543b86c0/Sources/NotesComponent/Store/FolderGuard.swift
[sweet-65]: https://github.com/sweetrb/apple-notes-mcp/blob/3dbf1538cedf5dd289f14dd11bcd202b70ed869f/src/tools/resourcesAndPrompts.ts
[storiz-66]: https://github.com/storizzi/notes-exporter/blob/ca6149232d0ed37ed281b53a27b24c4e283b6b70/README.md
[storiz-67]: https://github.com/storizzi/notes-exporter/blob/ca6149232d0ed37ed281b53a27b24c4e283b6b70/build_manifest.py
[storiz-68]: https://github.com/storizzi/notes-exporter/blob/ca6149232d0ed37ed281b53a27b24c4e283b6b70/prune_deleted.py
[storiz-69]: https://github.com/storizzi/notes-exporter/blob/ca6149232d0ed37ed281b53a27b24c4e283b6b70/notes_service/cli.py
[cider-70]: https://github.com/paradise-runner/cider/blob/eefb4f6ccbf54c2bbefdf4854014dd4c3771aa90/internal/cli/files.go
[frad-71]: https://github.com/FradSer/note/blob/5c8e283f7d332d6b97ccdccd633c2148fc0f894f/Sources/NoteCommands/SharedSyncCommands.swift
[nano-72]: https://github.com/shareup/nanotes/blob/0b0434f6659a076cfdbb612c45d41f077b0dbb32/commands/dump.ts
[card-73]: https://github.com/cardmagic/notes/blob/7445e3f3f13feeab506d0bf45866d6a0fc9dea29/src/attachments.ts
[xiao-74]: https://github.com/xiaofeng-han/apple-mcp/blob/3b18d907ca5b36f4ed0c660783273fd1543b86c0/Sources/NotesComponent/Store/Search.swift
[sweet-75]: https://github.com/sweetrb/apple-notes-mcp/blob/3dbf1538cedf5dd289f14dd11bcd202b70ed869f/src/utils/noteDrawings.ts
[sweet-76]: https://github.com/sweetrb/apple-notes-mcp/blob/3dbf1538cedf5dd289f14dd11bcd202b70ed869f/src/tools/svgAnalysis.ts
[sweet-77]: https://github.com/sweetrb/apple-notes-mcp/blob/3dbf1538cedf5dd289f14dd11bcd202b70ed869f/src/utils/audioTranscripts.ts
[apple-78]: https://github.com/danielhopkins/apple-tools/blob/e946c9e98330cd438418154145ef8b312a0f8e80/notes/mergeable.py
[sweet-79]: https://github.com/sweetrb/apple-notes-mcp/blob/3dbf1538cedf5dd289f14dd11bcd202b70ed869f/src/services/noteTranscription.ts
[xiao-80]: https://github.com/xiaofeng-han/apple-mcp/blob/3b18d907ca5b36f4ed0c660783273fd1543b86c0/Sources/NotesComponent/Tools/AttachmentTool.swift
[rparser-81]: https://github.com/RhetTbull/apple-notes-parser/blob/635efa0fb4813978eecc18a3b3bfcc2f04c80ba4/src/apple_notes_parser/embedded_objects.py
[xiao-82]: https://github.com/xiaofeng-han/apple-mcp/blob/3b18d907ca5b36f4ed0c660783273fd1543b86c0/Sources/NotesComponent/Tools/ReadTools.swift
[parser-83]: https://github.com/threeplanetssoftware/apple_cloud_notes_parser/blob/4754a2b62686570cca46690d101079e80cf6ae66/proto/notestore.proto
[rparser-84]: https://github.com/RhetTbull/apple-notes-parser/blob/635efa0fb4813978eecc18a3b3bfcc2f04c80ba4/src/apple_notes_parser/protobuf_parser.py
[sweet-85]: https://github.com/sweetrb/apple-notes-mcp/blob/3dbf1538cedf5dd289f14dd11bcd202b70ed869f/src/utils/noteRichText.ts
[parser-86]: https://github.com/threeplanetssoftware/apple_cloud_notes_parser/blob/4754a2b62686570cca46690d101079e80cf6ae66/lib/ProtoPatches.rb
[parser-87]: https://github.com/threeplanetssoftware/apple_cloud_notes_parser/blob/4754a2b62686570cca46690d101079e80cf6ae66/lib/AppleNotesEmbeddedTable.rb
[sweet-88]: https://github.com/sweetrb/apple-notes-mcp/blob/3dbf1538cedf5dd289f14dd11bcd202b70ed869f/src/utils/noteTables.ts
[ail-89]: https://github.com/ailenshen/apple-notes-mcp/blob/a7da277adacc5684114ab7038e0483b6e6aa7624/Sources/NotesKit/NotesShared/TableEditor.swift
[parser-90]: https://github.com/threeplanetssoftware/apple_cloud_notes_parser/blob/4754a2b62686570cca46690d101079e80cf6ae66/lib/AppleNotesEmbeddedGallery.rb
[sweet-91]: https://github.com/sweetrb/apple-notes-mcp/blob/3dbf1538cedf5dd289f14dd11bcd202b70ed869f/src/utils/attachmentAssets.ts
[xiao-92]: https://github.com/xiaofeng-han/apple-mcp/blob/3b18d907ca5b36f4ed0c660783273fd1543b86c0/Sources/NotesComponent/Store/Attachments.swift
[parser-93]: https://github.com/threeplanetssoftware/apple_cloud_notes_parser/blob/4754a2b62686570cca46690d101079e80cf6ae66/lib/AppleNotesEmbeddedDrawing.rb
[sweet-94]: https://github.com/sweetrb/apple-notes-mcp/blob/3dbf1538cedf5dd289f14dd11bcd202b70ed869f/src/utils/paperAttachments.ts
[parser-95]: https://github.com/threeplanetssoftware/apple_cloud_notes_parser/blob/4754a2b62686570cca46690d101079e80cf6ae66/lib/AppleUniformTypeIdentifier.rb
[parser-96]: https://github.com/threeplanetssoftware/apple_cloud_notes_parser/blob/4754a2b62686570cca46690d101079e80cf6ae66/lib/AppleNotesEmbeddedPublicJpeg.rb
[parser-97]: https://github.com/threeplanetssoftware/apple_cloud_notes_parser/blob/4754a2b62686570cca46690d101079e80cf6ae66/lib/AppleNotesEmbeddedPaperDocScan.rb
[parser-98]: https://github.com/threeplanetssoftware/apple_cloud_notes_parser/blob/4754a2b62686570cca46690d101079e80cf6ae66/lib/AppleNotesEmbeddedPDF.rb
[parser-99]: https://github.com/threeplanetssoftware/apple_cloud_notes_parser/blob/4754a2b62686570cca46690d101079e80cf6ae66/lib/AppleNotesEmbeddedPublicURL.rb
[parser-100]: https://github.com/threeplanetssoftware/apple_cloud_notes_parser/blob/4754a2b62686570cca46690d101079e80cf6ae66/lib/AppleNotesEmbeddedPublicVCard.rb
[parser-101]: https://github.com/threeplanetssoftware/apple_cloud_notes_parser/blob/4754a2b62686570cca46690d101079e80cf6ae66/lib/AppleNotesEmbeddedCalendar.rb
[parser-102]: https://github.com/threeplanetssoftware/apple_cloud_notes_parser/blob/4754a2b62686570cca46690d101079e80cf6ae66/lib/AppleNotesEmbeddedPublicAudio.rb
[sweet-103]: https://github.com/sweetrb/apple-notes-mcp/blob/3dbf1538cedf5dd289f14dd11bcd202b70ed869f/src/utils/noteAudio.ts
[parser-104]: https://github.com/threeplanetssoftware/apple_cloud_notes_parser/blob/4754a2b62686570cca46690d101079e80cf6ae66/lib/AppleNotesEmbeddedPublicVideo.rb
[parser-105]: https://github.com/threeplanetssoftware/apple_cloud_notes_parser/blob/4754a2b62686570cca46690d101079e80cf6ae66/lib/AppleNotesEmbeddedInlineHashtag.rb
[parser-106]: https://github.com/threeplanetssoftware/apple_cloud_notes_parser/blob/4754a2b62686570cca46690d101079e80cf6ae66/lib/AppleNotesEmbeddedInlineMention.rb
[parser-107]: https://github.com/threeplanetssoftware/apple_cloud_notes_parser/blob/4754a2b62686570cca46690d101079e80cf6ae66/lib/AppleNotesEmbeddedInlineLink.rb
[parser-108]: https://github.com/threeplanetssoftware/apple_cloud_notes_parser/blob/4754a2b62686570cca46690d101079e80cf6ae66/lib/AppleNotesEmbeddedInlineCalculateResult.rb
[xiao-109]: https://github.com/xiaofeng-han/apple-mcp/blob/3b18d907ca5b36f4ed0c660783273fd1543b86c0/Sources/NotesComponent/Store/BodyReader.swift
[parser-110]: https://github.com/threeplanetssoftware/apple_cloud_notes_parser/blob/4754a2b62686570cca46690d101079e80cf6ae66/lib/AppleNotesEmbeddedInlineCalculateGraphExpression.rb
[parser-111]: https://github.com/threeplanetssoftware/apple_cloud_notes_parser/blob/4754a2b62686570cca46690d101079e80cf6ae66/lib/AppleNotesEmbeddedObject.rb
[parser-112]: https://github.com/threeplanetssoftware/apple_cloud_notes_parser/blob/4754a2b62686570cca46690d101079e80cf6ae66/lib/AppleNotesEmbeddedDocument.rb
[parser-113]: https://github.com/threeplanetssoftware/apple_cloud_notes_parser/blob/4754a2b62686570cca46690d101079e80cf6ae66/lib/AppleNotesEmbeddedPublicObject.rb
[ail-114]: https://github.com/ailenshen/apple-notes-mcp/blob/a7da277adacc5684114ab7038e0483b6e6aa7624/Sources/NotesKit/NotesShared/Attachments.swift
[memo-115]: https://github.com/antoniorodr/memo/blob/1cf73cd47dff7a7d35f3a1dc51be483bcb8b65a2/README.md
[mk-116]: https://github.com/johnmatthewtennant/notekit-cli/blob/dcfdb5b25b8932d98cc66d625e71a69d80e9ad70/README.md
[javi-117]: https://github.com/JaviSoto/apple-notes-cli/blob/aabdb456ab749f40eab352c6884a26df6d1b075f/README.md
[xwmx-118]: https://github.com/xwmx/notes-app-cli/blob/422798ace09ca97bd6009b91b90c1795b8208b12/README.md
[card-119]: https://github.com/cardmagic/notes/blob/7445e3f3f13feeab506d0bf45866d6a0fc9dea29/README.md
[card-120]: https://github.com/cardmagic/notes/blob/7445e3f3f13feeab506d0bf45866d6a0fc9dea29/src/mcp.ts
[sweet-121]: https://github.com/sweetrb/apple-notes-mcp/blob/3dbf1538cedf5dd289f14dd11bcd202b70ed869f/README.md
[sweet-122]: https://github.com/sweetrb/apple-notes-mcp/blob/3dbf1538cedf5dd289f14dd11bcd202b70ed869f/src/tools/folderDelete.ts
[sweet-123]: https://github.com/sweetrb/apple-notes-mcp/blob/3dbf1538cedf5dd289f14dd11bcd202b70ed869f/src/tools/markdownTemplates.ts
[sweet-124]: https://github.com/sweetrb/apple-notes-mcp/blob/3dbf1538cedf5dd289f14dd11bcd202b70ed869f/src/tools/nativeTagsBridge.ts
[sweet-125]: https://github.com/sweetrb/apple-notes-mcp/blob/3dbf1538cedf5dd289f14dd11bcd202b70ed869f/src/tools/privateHelperTools.ts
[apple-126]: https://github.com/danielhopkins/apple-tools/blob/e946c9e98330cd438418154145ef8b312a0f8e80/README.md
[apple-127]: https://github.com/danielhopkins/apple-tools/blob/e946c9e98330cd438418154145ef8b312a0f8e80/notes/notestore.py
[cloud-128]: https://github.com/coddingtonbear/icloud-md/blob/ffa20ef6378a453f0935d26f03acedf3e58540f2/README.md
[parser-129]: https://github.com/threeplanetssoftware/apple_cloud_notes_parser/blob/4754a2b62686570cca46690d101079e80cf6ae66/README.md
[dog-130]: https://github.com/dogsheep/apple-notes-to-sqlite/blob/e55a802d37a896475b6cf475c1ba947af63cca73/README.md
[honey-131]: https://github.com/mattjefferson/honeycrisp/blob/e303352470683896c2802f46b0d1629779f60c29/README.md
[cider-132]: https://github.com/paradise-runner/cider/blob/eefb4f6ccbf54c2bbefdf4854014dd4c3771aa90/README.md
[cider-133]: https://github.com/paradise-runner/cider/blob/eefb4f6ccbf54c2bbefdf4854014dd4c3771aa90/internal/cli/push.go
[cider-134]: https://github.com/paradise-runner/cider/blob/eefb4f6ccbf54c2bbefdf4854014dd4c3771aa90/internal/cli/pull.go
[cider-135]: https://github.com/paradise-runner/cider/blob/eefb4f6ccbf54c2bbefdf4854014dd4c3771aa90/internal/cli/diff.go
[biao-136]: https://github.com/biao29/notesctl/blob/d5a2e43b040b5e3d214a409366a740416ed4b70e/README.md
[frad-137]: https://github.com/FradSer/note/blob/5c8e283f7d332d6b97ccdccd633c2148fc0f894f/README.md
[frad-138]: https://github.com/FradSer/note/blob/5c8e283f7d332d6b97ccdccd633c2148fc0f894f/Sources/note/Commands/FolderCommands.swift
[frad-139]: https://github.com/FradSer/note/blob/5c8e283f7d332d6b97ccdccd633c2148fc0f894f/Sources/note/Commands/SyncCommands.swift
[frad-140]: https://github.com/FradSer/note/blob/5c8e283f7d332d6b97ccdccd633c2148fc0f894f/Sources/note/Commands/SyncDirectCommands.swift
[frad-141]: https://github.com/FradSer/note/blob/5c8e283f7d332d6b97ccdccd633c2148fc0f894f/Sources/note/Commands/PreferencesCommand.swift
[frad-142]: https://github.com/FradSer/note/blob/5c8e283f7d332d6b97ccdccd633c2148fc0f894f/Sources/NoteCommands/SyncDaemonCommands.swift
[angel-143]: https://github.com/angelespejo/apple-notes-cli/blob/9e29fd74a64b663feb760e1431184e47664bacfb/README.md
[raf-144]: https://github.com/RafalWilinski/mcp-apple-notes/blob/b95a40ae858d791cd54e2a52700041bb2728fbe6/README.md
[kyl-145]: https://github.com/Kylmakalle/apple-notes-exporter/blob/1d1b727ccbaaa1c98f846a2c2d21f851cc4b276a/Readme.md
[kyl-146]: https://github.com/Kylmakalle/apple-notes-exporter/blob/1d1b727ccbaaa1c98f846a2c2d21f851cc4b276a/scripts/organize.py
[kyl-147]: https://github.com/Kylmakalle/apple-notes-exporter/blob/1d1b727ccbaaa1c98f846a2c2d21f851cc4b276a/scripts/patch_image_paths.py
[sir-148]: https://github.com/sirmews/apple-notes-mcp/blob/d4cfb110b8141bf16d7db08b8573e54192cf4873/README.md
[kras-149]: https://github.com/krasun/notes-mcp/blob/41b8a440f560da891e03aa65728e9636b6916d11/README.md
[hen-150]: https://github.com/henilcalagiya/mcp-apple-notes/blob/ca9df02bbb83757b58880f5f2d82afa4c8777656/README.md
[rod-151]: https://github.com/RodriguesJohn/applenotesmcp/blob/109b863c34e001b50e17911d0d797964cc701ccd/README.md
[sid-152]: https://github.com/Siddhant-K-code/mcp-apple-notes/blob/539fd1858192e4038fc49a21bd30bd610cc47c1b/README.md
[ail-153]: https://github.com/ailenshen/apple-notes-mcp/blob/a7da277adacc5684114ab7038e0483b6e6aa7624/README.md
[ail-154]: https://github.com/ailenshen/apple-notes-mcp/blob/a7da277adacc5684114ab7038e0483b6e6aa7624/Sources/AppleNotesMCP/main.swift
[ail-155]: https://github.com/ailenshen/apple-notes-mcp/blob/a7da277adacc5684114ab7038e0483b6e6aa7624/Sources/AppleNotesMCP/MCP/ReadTools.swift
[ail-156]: https://github.com/ailenshen/apple-notes-mcp/blob/a7da277adacc5684114ab7038e0483b6e6aa7624/Sources/AppleNotesMCP/MCP/AttachmentTool.swift
[dan-157]: https://github.com/Dan8Oren/mcp-apple-notes/blob/6917c2df2e2217fd16c4889697a2658a498b230d/README.md
[mcol-158]: https://github.com/mcolyer/mcp-apple-notes-py/blob/9e730ebd629cd9b3a276de18410bc7982ecf1587/README.md
[disco-159]: https://github.com/disco-trooper/apple-notes-mcp/blob/58ba7c68d40994e37d02ceb6db10a10ab1ddcf81/README.md
[stash-160]: https://github.com/shakedlokits/stash/blob/e083a2ec5c89508b211db3e9865c7ee5efb19977/README.md
[nano-161]: https://github.com/shareup/nanotes/blob/0b0434f6659a076cfdbb612c45d41f077b0dbb32/README.md
[memory-162]: https://github.com/honeybluesky/my-apple-remembers/blob/41c77788da6a76c07532b49a4e99b5b70ffeb984/README.md
[tom-163]: https://github.com/Tom-Semple/mcp-apple-notes-fixed/blob/1f51ac195a9902d6405b6017f8666a38db598847/README.md
[rparser-164]: https://github.com/RhetTbull/apple-notes-parser/blob/635efa0fb4813978eecc18a3b3bfcc2f04c80ba4/README.md
[utils-165]: https://github.com/dunhamsteve/notesutils/blob/582e569c9d0a6b398e91099260eaf761366a5f68/README.md
[utils-166]: https://github.com/dunhamsteve/notesutils/blob/582e569c9d0a6b398e91099260eaf761366a5f68/notes2bear
[utils-167]: https://github.com/dunhamsteve/notesutils/blob/582e569c9d0a6b398e91099260eaf761366a5f68/notes2quiver
[storiz-168]: https://github.com/storizzi/notes-exporter/blob/ca6149232d0ed37ed281b53a27b24c4e283b6b70/qdrant_integration.py
[storiz-169]: https://github.com/storizzi/notes-exporter/blob/ca6149232d0ed37ed281b53a27b24c4e283b6b70/sync_to_notes.py
[storiz-170]: https://github.com/storizzi/notes-exporter/blob/ca6149232d0ed37ed281b53a27b24c4e283b6b70/reconcile.py
[storiz-171]: https://github.com/storizzi/notes-exporter/blob/ca6149232d0ed37ed281b53a27b24c4e283b6b70/tracker_io.py
[storiz-172]: https://github.com/storizzi/notes-exporter/blob/ca6149232d0ed37ed281b53a27b24c4e283b6b70/notes_db.py
[storiz-173]: https://github.com/storizzi/notes-exporter/blob/ca6149232d0ed37ed281b53a27b24c4e283b6b70/events.py
[storiz-174]: https://github.com/storizzi/notes-exporter/blob/ca6149232d0ed37ed281b53a27b24c4e283b6b70/setup_launchd.py
[storiz-175]: https://github.com/storizzi/notes-exporter/blob/ca6149232d0ed37ed281b53a27b24c4e283b6b70/notes_permission.py
[alex-176]: https://github.com/alexwlchan/notes-export/blob/fc5194e79141ef37a9b3f69b5d2ff9cadd71fad8/README.md
[joplin-177]: https://github.com/mattrose/AppleNotes2Joplin/blob/2540c4d6fbeb6972dfa61424be0e9ff86e84de10/README.md
[imcp-178]: https://github.com/mattt/iMCP/blob/c30e84cef24e2554ba5e128b1b8280e09586d5b4/README.md
[xiao-179]: https://github.com/xiaofeng-han/apple-mcp/blob/3b18d907ca5b36f4ed0c660783273fd1543b86c0/README.md
[xiao-180]: https://github.com/xiaofeng-han/apple-mcp/blob/3b18d907ca5b36f4ed0c660783273fd1543b86c0/Sources/AppCore/CLI/Commands.swift
