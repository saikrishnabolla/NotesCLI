# Apple Notes feature inventory

Verified on macOS 27.2.1 on 2026-11-12. Apple documents the user-facing features in the [Notes User Guide](https://support.apple.com/guide/notes/welcome/mac), including [formatting](https://support.apple.com/en-ca/guide/notes/apd1955d3b21/mac), [lists](https://support.apple.com/en-ca/guide/notes/apd93c815aa0/mac), [attachments](https://support.apple.com/en-ae/guide/notes/not95edd2813/mac), [sorting and pinning](https://support.apple.com/en-ie/guide/notes/apdb54e469b6/mac), [Smart Folders](https://support.apple.com/en-ph/guide/notes/apd58edc7964/mac), [sharing](https://support.apple.com/en-ie/guide/notes/apda5307056b/mac), and [settings](https://support.apple.com/en-ie/guide/notes/apd97da26aed/mac). Runtime inspection of Notes.app and NotesShared found `ICTTParagraphStyle`, `ICTTFont`, `TTEmphasis`, `NSSuperScript`, `TTColor`, `ICOutlineState`, and their checked setters. Protobuf probes confirmed paragraph fields 1, 2, 3, 4, 6, 7, and 9, plus highlight field 14. The field-14 result agrees with [apple_cloud_notes_parser's schema](https://github.com/threeplanetssoftware/apple_cloud_notes_parser/blob/master/proto/notestore.proto). “Read” and “Write” below describe NotesCLI, not Notes.app.

Read status: 85 Done, 5 Partial, and 4 Not possible. Write status: 63 Done, 8 Partial, and 23 Not possible. The matrix has 94 rows and no Missing status. `notescli capabilities` and MCP `get_capabilities` use the same feature names and statuses; a literal parity test checks this table against the runtime catalog.

| Feature | Read | Write | Notes |
| --- | --- | --- | --- |
| Title style | Done | Done | Native paragraph style 0. Scripting imports `<h1>` as 24px bold body text; use `--engine native` for a native Title. |
| Heading style | Done | Done | Native paragraph style 1. Scripting imports `<h2>` as 18px bold body text; use `--engine native` for a native Heading. |
| Subheading style | Done | Done | Native paragraph style 2. Scripting imports `<h3>` as bold body text; use `--engine native` for a native Subheading. |
| Body style | Done | Done | Native paragraph style 3. |
| Monospaced style | Done | Done | Native paragraph style 4. |
| Block quote | Done | Done | Paragraph style and quote level are preserved. |
| Paragraph indentation | Done | Done | Native indent level is preserved. |
| Left, center, right, and justified alignment | Done | Done | `ICTTParagraphStyle.alignment`. |
| Natural, left-to-right, and right-to-left writing direction | Done | Done | Native value is decoded and written through the checked setter. |
| Bold | Done | Done | Native font hint. |
| Italic | Done | Done | Native font hint. |
| Underline | Done | Done | Native run attribute. |
| Strikethrough | Done | Done | Native run attribute. |
| Superscript | Done | Done | `NSSuperScript` value 1. |
| Subscript | Done | Done | `NSSuperScript` value -1. |
| Font family | Done | Done | `ICTTFont` name is decoded and constructed with checked selectors. |
| Font size | Done | Done | `ICTTFont` point size is decoded and constructed with checked selectors. |
| Foreground text color | Done | Done | Native `TTColor` attribute. |
| Purple highlight | Done | Done | Highlight field 14 value 1; rendered as semantic `mark`. |
| Pink highlight | Done | Done | Highlight field 14 value 2. |
| Orange highlight | Done | Done | Highlight field 14 value 3. |
| Mint highlight | Done | Done | Highlight field 14 value 4. |
| Blue highlight | Done | Done | Highlight field 14 value 5. |
| Clear inline formatting | Done | Done | Individual native attributes can be removed without replacing the body. |
| Collapsible headings and subheadings | Done | Done | UUIDs are read from `ICOutlineState`; writes replace the checked outline-state payload. |
| Bulleted lists | Done | Done | Native paragraph list style. |
| Dashed lists | Done | Done | Native paragraph list style. |
| Numbered lists and starting number | Done | Done | Style and starting item number are preserved. |
| Nested lists | Done | Done | List style plus indent level. |
| Checklists | Done | Done | Native todo paragraph state, including checked state. |
| Checklist sorting preference | Done | Done | Reads and writes `ICChecklistAutoSortEnabledDefaultsKey` for Notes, with exact preference readback. |
| Native tables | Done | Done | Rows, columns, identities, and text support readback and structural edits. |
| Add or remove table rows and columns | Done | Done | Native table operations. |
| Table cell text | Done | Done | Cells can be read and set by row and column. |
| Table cell rich formatting | Done | Done | Cell runs retain bold, italic, underline, strike, links, colors, highlights, font, and script. `table format-cell` writes them through `ICTable.setAttributedString:columnIndex:rowIndex:` and verifies native and SQLite readback. |
| Convert table to text | Done | Done | `table convert-to-text` replaces the native table marker with tab- or comma-separated text and verifies the table was deleted. |
| External web links | Done | Done | Native link runs retain URL and label. |
| Native note-to-note links | Done | Done | Target UUID and display text are preserved. |
| Paragraph links and persistent anchors | Done | Done | Paragraph UUIDs and local anchor resolution are supported. |
| URL preview cards | Done | Done | Native URL cards are decoded and inserted. |
| Native tags | Done | Done | Tag identity, counts, add, replace, and remove are supported. |
| Mentions | Done | Partial | `ICInlineAttachment.newMentionAttachmentWithIdentifier:mentionText:userRecordName:note:parentAttachment:` creates mentions in shared notes. NotesCLI requires `--allow-shared`; participant notification behavior was not verified in an isolated account. |
| Photos and images | Done | Done | Metadata, originals, previews, insertion, and export. |
| Videos | Done | Done | Original media and preview frames are available; files can be inserted. |
| PDFs | Done | Done | Original, preview, indexed text, insertion, and export. |
| General file attachments | Done | Done | Original bytes and metadata are preserved. |
| Maps and location cards | Done | Not possible | Runtime inspection found `ICAttachment.addLocationWithLatitude:longitude:` and `ICAttachmentLocation.newAttachmentLocationForAttachment:`. Both require an existing attachment; no map-card attachment constructor or map UTI factory was found. |
| Contact cards | Done | Not possible | `public.vcard` files remain insertable as generic attachments. Runtime inspection of NotesShared and Notes.app found contact display selectors but no selector-checked contact-card attachment constructor. |
| Scanned documents | Done | Not possible | Runtime inspection found `addGalleryAttachmentWithIdentifier:` and `addPaperDocumentAttachmentWithIdentifier:subtype:`, but no selector that imports image or PDF bytes into a complete scan gallery with its required mergeable data. |
| Image and PDF markup | Partial | Not possible | Runtime selector listings expose rendered assets but no constructor or setter for an editable markup graph. |
| Classic drawings and sketches | Done | Not possible | Runtime inspection of drawing attachment classes found read/export properties but no stroke-object constructor that can be selector-checked. |
| Modern Paper drawings | Done | Done | `ICPaperAttachmentCreationHelper.createSystemPaperAttachmentWithPKDrawing:inNote:` creates editable `com.apple.paper` attachments. `ICSystemPaperDrawingsHelper.drawingsForAttachment:` returns their PencilKit strokes for SVG and PNG export. Native and SQLite readback verified attachment identity, placement, and stroke count; Notes.app rendered the result. |
| Audio file attachments | Done | Done | Original audio can be fetched, exported, and inserted. |
| Native audio recordings | Done | Not possible | NotesShared exposes `ICNote.addAudioAttachmentWithIdentifier:`, `ICAttachmentAudioModel.createSubattachmentForRecordingAndReturnError:`, `setRecordedInNotes:`, and `transformNewlyAddedMediaAttachment`. It exposes no checked audio-file initializer that builds the recorder container, fragment assets, and mergeable recording data as one valid object. |
| Stored audio transcripts | Done | Not possible | Runtime transcript classes expose stored segments, timing, and speakers, but no checked constructor or note setter for generated transcript data. |
| Recording summaries and call metadata | Done | Not possible | Runtime listings expose stored summary and call fields but no constructor or generation selector. |
| Math expressions, results, and graphs | Done | Partial | `newCalculateGraphExpressionAttachmentWithIdentifier:altText:note:parentAttachment:rightToLeft:` creates a native expression object. Notes still owns result evaluation and graph rendering. |
| Divider lines | Done | Done | `newDividerLineAttachmentWithIdentifier:note:parentAttachment:` creates the native divider and exact native and SQLite readback verifies it. |
| Pin and unpin | Done | Done | Native pinned state is readable and writable. |
| Locked-note state | Done | Not possible | `ICNote` exposes lock-state getters, but runtime inspection found no authenticated unlock or key-management write contract suitable for a background CLI. |
| Share state and participants | Done | Not possible | Share and participant objects expose read properties; runtime selector listings found no stable invitation, removal, or access-right mutation contract. |
| Edit an existing shared note | Done | Done | Native writes require an explicit shared-note opt-in and reject read-only or unknown roles. |
| Collaboration activity and changes | Partial | Not possible | Notes.app contains activity-view controllers, but NotesShared exposes no persistent activity-history fetch or mutation selector. |
| Accounts and default location | Done | Partial | Accounts are listed and selected for writes; account creation and settings remain system-owned. |
| Folders and subfolders | Done | Done | Create, rename, move, list, and guarded recursive delete are supported. |
| Recently Deleted | Done | Done | Listing and restore are supported; permanent deletion is intentionally excluded. |
| Smart Folders and rules | Done | Done | Rules support `type` around one rule; `and`, `or`, and `not`; Boolean note flags; tags, folders, participants, attachment sections 1 through 7, and absolute or relative creation and modification dates. A `type` rule cannot have siblings. Native writes compare exact `smartFolderQueryJSON` readback. |
| Quick Notes | Done | Partial | Quick Notes are detected and their folder can be targeted; hot-corner and capture metadata are app-owned. |
| Folder list and gallery views | Not possible | Not possible | Runtime inspection found these modes only on Notes.app view-controller selectors, with no NotesShared folder property to read or write. |
| Folder sort options | Done | Done | `folder sort` reads and writes `ICFolder.customNoteSortType`. Live probes confirmed modified 10/11, created 20/21, and title 30/31. |
| Folder grouping by date | Done | Not possible | `folder sort` reads `ICFolder.isShowingDateHeaders`. Runtime inspection found no `setShowingDateHeaders:` or other NotesShared grouping setter. |
| Note display order | Done | Partial | Stored display order is read and exported. SQLite has `ZSORTORDER`, but runtime inspection found no checked `ICNote.setSortOrder:` selector for manual or pinned ordering. |
| Search by title and body | Done | Not possible | NotesShared exposes fetch/search paths, but search is a read operation with no persistent object to mutate. |
| Search filters and Boolean queries | Done | Not possible | Dates, tags, pins, folders, and attachment kinds are query predicates; runtime inspection found no writable query object on notes. |
| OCR and image labels | Done | Not possible | Attachment recognition properties are readable, but runtime listings found no selector that requests or writes Notes' OCR and label payloads. |
| Handwriting recognition | Done | Not possible | Paper attachments expose stored handwriting text, but no selector starts recognition or writes its result. |
| PDF text search | Done | Not possible | NotesShared exposes cached PDF text for reads but no setter or indexing request selector. |
| Audio transcript search | Done | Not possible | Transcript text is readable; search has no persistent write target or runtime mutation selector. |
| Import plain text, HTML, and Markdown | Done | Done | New and existing notes support file, standard input, and Markdown workflows. |
| Export Markdown and HTML | Done | Done | Folder trees and original attachments are supported. |
| Export JSON, NDJSON, and SQLite | Done | Done | Structured and normalized exports are supported. |
| Export PDF, DOCX, RTF, and EPUB | Done | Done | PDF supports combined output; EPUB preserves folder chapters. |
| Export Bear, Joplin, Quiver, TextBundle, and ZIP | Done | Done | Merged export formats are reflected here. |
| Print | Not possible | Not possible | Notes.app exposes print-panel actions, but runtime inspection found no headless NotesShared print read or write API. |
| Widgets | Not possible | Not possible | Widget classes live in system UI extensions; NotesShared exposes no widget state property or mutation selector. |
| Note notifications | Partial | Not possible | Collaboration metadata can be read, but runtime listings found no NotesShared notification-delivery setting or setter. |
| Notes settings | Partial | Partial | Checklist auto-sort is readable and writable through `ICChecklistAutoSortEnabledDefaultsKey`; no stable NotesShared contract covers every app preference. |
| Default account | Done | Done | `accounts` reads the default account. `accounts --set-default` uses checked `ICDefaultAccountUtilities.defaultAccount` and `setDefaultAccountIdentifier:` selectors, then reads the identifier back. |
| Default paragraph style | Not possible | Not possible | `ICTTParagraphStyle.defaultParagraphStyle` is a style factory, not the Notes preference. Notes.app contains `setNoteDefaultNamedStyle:`, but runtime inspection found no selector-checked NotesShared owner or matching preference getter. |
| Note links and Share-sheet capture | Done | Partial | Deep links and inserted content work; invoking another app's Share sheet is outside the CLI. |
| Open notes, folders, accounts, and attachments | Done | Done | NotesCLI can ask Notes or Finder to reveal the selected object. |
| Sync and upload state | Done | Done | State is readable; writes can request upload and wait for bounded acknowledgement. |
| Version history, diff, undo, and revert | Partial | Partial | Native-only snapshots return `native_required` on the scripting engine. `--engine native` restores saved runs, checklists, links, highlights, attachment markers, and rich table cells. A fresh SQLite decode verifies the note ID and title, text and runs, tables and rich cells, and attachment IDs, types, and parent relationships. It does not compare attachment file bytes. `--allow-downgrade` permits scripting conversion. Native attachment restore requires the original Notes attachment object. Setting and Smart Folder rule writes can restore recorded preimages by journal operation ID. |
| Multiple iCloud, local, and IMAP accounts | Done | Done | Reads and supported writes resolve the account and folder explicitly. |

