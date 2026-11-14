# Apple Notes feature inventory

Verified on macOS 27.2.1 on 2026-11-13. Apple documents the user-facing features in the [Notes User Guide](https://support.apple.com/guide/notes/welcome/mac), including [formatting](https://support.apple.com/en-ca/guide/notes/apd1955d3b21/mac), [lists](https://support.apple.com/en-ca/guide/notes/apd93c815aa0/mac), [attachments](https://support.apple.com/en-ae/guide/notes/not95edd2813/mac), [sorting and pinning](https://support.apple.com/en-ie/guide/notes/apdb54e469b6/mac), [Smart Folders](https://support.apple.com/en-ph/guide/notes/apd58edc7964/mac), [sharing](https://support.apple.com/en-ie/guide/notes/apda5307056b/mac), and [settings](https://support.apple.com/en-ie/guide/notes/apd97da26aed/mac). Runtime inspection of Notes.app and NotesShared found `ICTTParagraphStyle`, `ICTTFont`, `TTEmphasis`, `NSSuperScript`, `TTColor`, `ICOutlineState`, and their checked setters. Protobuf probes confirmed paragraph fields 1, 2, 3, 4, 6, 7, and 9, plus highlight field 14. The field-14 result agrees with [apple_cloud_notes_parser's schema](https://github.com/threeplanetssoftware/apple_cloud_notes_parser/blob/master/proto/notestore.proto). “Read” and “Write” below describe NotesCLI, not Notes.app.

Read status: 87 Done, 5 Partial, and 3 Not possible. Write status: 72 Done, 8 Partial, and 15 Not possible. The matrix has 95 rows and no Missing status. `notescli capabilities` and MCP `get_capabilities` use the same feature names and statuses; a literal parity test checks this table against the runtime catalog.

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
| Paragraph links and persistent anchors | Done | Done | NotesCLI creates native links to a note or one of its paragraphs. It validates the target paragraph, preserves paragraph UUIDs during history restoration, and also supports local anchors. |
| URL preview cards | Done | Done | Native URL cards are decoded and inserted. |
| Native tags | Done | Done | Tag identity, counts, add, replace, and remove are supported. |
| Mentions | Done | Partial | `ICInlineAttachment.newMentionAttachmentWithIdentifier:mentionText:userRecordName:note:parentAttachment:` creates mentions in shared notes. NotesCLI requires `--allow-shared`; participant notification behavior was not verified in an isolated account. |
| Photos and images | Done | Done | Metadata, originals, previews, insertion, and export. |
| Editorial SVG and HTML diagrams | Done | Done | Image mode renders through WebKit to a cropped 2x or 3x PNG with recoverable source metadata. Drawing mode converts supported SVG shapes and paths to editable Paper strokes. |
| Videos | Done | Done | Original media and preview frames are available; files can be inserted. |
| PDFs | Done | Done | Original, preview, indexed text, insertion, and export. |
| General file attachments | Done | Done | Original bytes and metadata are preserved. |
| Maps and location cards | Done | Done | `map add` creates an Apple Maps URL attachment, calls the checked `addLocationIfNeeded` selector, and verifies the native `ICAttachmentMapModel` and stored location through fresh SQLite readback. URLs must use `https://maps.apple.com`. |
| Contact cards | Done | Not possible | `public.vcard` files remain insertable as generic attachments. Runtime inspection of NotesShared and Notes.app found contact display selectors but no selector-checked contact-card attachment constructor. |
| Scanned documents | Done | Partial | `scan add` and `scan append` write ordered native `com.apple.notes.gallery` pages. Page state, filter, rotation, crop, move, and delete use checked native selectors with fresh native and SQLite readback. History restores scan markup and checks each page with a 256×256 visual comparison before committing the ordered transaction. Crops convert normalized input to Notes' top-left-origin pixel coordinates and refuse rotated or marked-up pages. Camera capture, edge detection, perspective correction, editable markup, and visible Mac/iPhone/PDF crop proof remain absent. |
| Image and PDF markup | Partial | Not possible | Runtime selector listings expose rendered assets but no constructor or setter for an editable markup graph. |
| Classic drawings and sketches | Done | Done | NotesCLI decodes classic drawing strokes and creates editable legacy drawing attachments from validated stroke records. History restoration recreates and verifies the stroke payload through fresh reads. |
| Modern Paper drawings | Done | Done | `ICPaperAttachmentCreationHelper.createSystemPaperAttachmentWithPKDrawing:inNote:` creates editable `com.apple.paper` attachments. `ICSystemPaperDrawingsHelper.drawingsForAttachment:` returns their PencilKit strokes for SVG and PNG export. Native readback compares each stroke's ink, color, width, and points with the input, allowing the single shift Notes applies to the whole drawing; SQLite readback checks attachment identity and placement. Creation and rendering in Notes.app on the Mac are verified. A drawing created by notescli was edited with Apple Pencil on iPad, synced back, and read with every original and new stroke. |
| Audio file attachments | Done | Done | Original audio can be fetched, exported, and inserted. |
| Native audio recordings | Done | Done | `recording add` and `recording create` convert input with AVFoundation, then use checked `ICAttachmentAudioModel` selectors to create the recorder container, fragment child, duration, and mergeable recording data. Fresh SQLite readback verifies the graph and media hash. |
| Stored audio transcripts | Done | Done | `recording transcribe` transcribes a recording on device and stores the result in the note; `recording transcribe-file` writes timed on-device Speech results without opening Notes. Verified live on macOS 27. `--transcript-file` stores those segments as native `ICTTTranscriptSegment` objects in the recording CRDT. `recording transcript` reads Notes transcripts as text, SRT, VTT, or JSON. |
| Recording summaries and call metadata | Done | Not possible | Runtime listings expose stored summary and call fields but no constructor or generation selector. |
| Math expressions, results, and graphs | Done | Partial | `format math` creates a native graph-expression object. `math evaluate` uses Apple's Calculate framework, and `math insert-result` stores the same plain-text `expression=result` representation produced by Notes' Insert Results action. Notes still owns interactive recognition and graph rendering. |
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
| Folder grouping by date | Done | Done | `folder group-by-date` reads `isShowingDateHeaders` and writes through `applyDateHeadersType:`. Native and SQLite readback verify the setting. The journal preserves inherited, off, and on as separate states. |
| Note display order | Done | Partial | Stored display order is read and exported. SQLite has `ZSORTORDER`, but runtime inspection found no checked `ICNote.setSortOrder:` selector for manual or pinned ordering. |
| Search by title and body | Done | Not possible | NotesShared exposes fetch/search paths, but search is a read operation with no persistent object to mutate. |
| Search filters and Boolean queries | Done | Not possible | Dates, tags, pins, folders, and attachment kinds are query predicates; runtime inspection found no writable query object on notes. |
| OCR and image labels | Done | Not possible | Stored OCR, image labels, and summaries are readable. `ocr` and MCP `ocr_attachment` can run Notes' checked image recognizer on a downloaded image without changing the attachment. NotesCLI cannot persist Notes' private recognition payloads. |
| Handwriting recognition | Done | Done | `handwriting recognize --persist` runs Apple's checked recognizer and saves its text. `handwriting set` replaces or clears the stored handwriting summary. Native and SQLite readback verify the saved value. |
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
| Notes settings | Partial | Partial | Global sort, date grouping, default text size, Quick Note resume, automatic tag conversion, default paragraph style, and checklist auto-sort are readable and writable. Live tests verify Notes' app-group values; UI typing verified automatic tag conversion. No stable NotesShared contract covers every app preference. |
| Default account | Done | Done | `accounts` reads the default account. `accounts --set-default` writes and verifies `DefaultNotesAccount` in Notes' app-group preferences file. |
| Default paragraph style | Done | Done | `settings default-style` reads and writes `TTTextControllerNoteDefaultNamedStyleKey` in Notes' app-group preferences file, with `ICTextStyle.noteDefaultNamedStyle` as the default-value fallback. It supports title, heading, subheading, body, and monospaced, verifies exact readback, and records the previous value in the journal. |
| Note links and Share-sheet capture | Done | Done | `link capture` and MCP `link_capture` create Notes' native Synapse web attachment with `SYContentItem` and `addSynapseLinkAttachmentWithContentItem:`. Native decode, one body marker, nonempty SQLite Synapse data, idempotent replay, and exact undo were verified live. Opening another app's Share-sheet UI remains outside the CLI. |
| Open notes, folders, accounts, and attachments | Done | Done | NotesCLI can ask Notes or Finder to reveal the selected object. |
| Sync and upload state | Done | Done | State is readable; writes can request upload and wait for bounded acknowledgement. |
| Version history, diff, undo, and revert | Partial | Partial | NotesCLI keeps exact pre-write snapshots for its own writes; Apple exposes no complete Notes version-history API for earlier edits. Native restore recreates missing scans and markup, recordings and fragments, Paper documents, multi-canvas System Paper, modern and classic drawings, rich links, maps, tables, table-cell inline objects, paragraph links, PDFs, images, and files, including types without a canonical extension. It restores title and pin state, preserves paragraph and checklist UUIDs, remaps attachment IDs, restores private payloads, and verifies structure and archived bytes through fresh native and database reads. Paper verification compares semantic asset contents because Notes rewrites the CRDT and database bytes. A failed Paper restore uses guarded cleanup but still reports `unknown`. Unknown future attachment graphs are refused. Password-locked V1 and V1 Neo snapshots require a password during capture; device-key/passcode V2 and sidecar-v3 remain unavailable. Shared-note writes require `--allow-shared`; participant and share records are not versioned. `--allow-downgrade` permits scripting conversion. Setting and Smart Folder rule writes restore recorded preimages only when the recorded result state still matches. |
| Multiple iCloud, local, and IMAP accounts | Done | Done | Reads and supported writes resolve the account and folder explicitly. |

