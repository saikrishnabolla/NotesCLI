# Apple Notes feature inventory

Verified on macOS 27.2.1 on 2026-11-11. Apple documents the user-facing features in the [Notes User Guide](https://support.apple.com/guide/notes/welcome/mac), including [formatting](https://support.apple.com/en-ca/guide/notes/apd1955d3b21/mac), [lists](https://support.apple.com/en-ca/guide/notes/apd93c815aa0/mac), [attachments](https://support.apple.com/en-ae/guide/notes/not95edd2813/mac), [sorting and pinning](https://support.apple.com/en-ie/guide/notes/apdb54e469b6/mac), [Smart Folders](https://support.apple.com/en-ph/guide/notes/apd58edc7964/mac), [sharing](https://support.apple.com/en-ie/guide/notes/apda5307056b/mac), and [settings](https://support.apple.com/en-ie/guide/notes/apd97da26aed/mac). Runtime inspection of Notes.app and NotesShared found `ICTTParagraphStyle`, `ICTTFont`, `TTEmphasis`, `NSSuperScript`, `TTColor`, `ICOutlineState`, and their checked setters. Protobuf probes confirmed paragraph fields 1, 2, 3, 4, 6, 7, and 9, plus highlight field 14. The field-14 result agrees with [apple_cloud_notes_parser's schema](https://github.com/threeplanetssoftware/apple_cloud_notes_parser/blob/master/proto/notestore.proto). “Read” and “Write” below describe NotesCLI, not Notes.app.

| Feature | Read | Write | Notes |
| --- | --- | --- | --- |
| Title style | Done | Done | Native paragraph style 0. |
| Heading style | Done | Done | Native paragraph style 1. |
| Subheading style | Done | Done | Native paragraph style 2. |
| Body style | Done | Done | Native paragraph style 4. |
| Monospaced style | Done | Done | Native paragraph style 100. |
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
| Checklist sorting preference | Partial | Missing | Item state is available; the Notes setting that moves checked items is not exposed. |
| Native tables | Done | Done | Rows, columns, identities, and text support readback and structural edits. |
| Add or remove table rows and columns | Done | Done | Native table operations. |
| Table cell text | Done | Done | Cells can be read and set by row and column. |
| Table cell rich formatting | Partial | Partial | Cell text is complete; arbitrary run attributes inside every cell are not yet round-tripped. |
| Convert table to text | Done | Missing | Markdown/CSV export is available; no in-note destructive conversion command. |
| External web links | Done | Done | Native link runs retain URL and label. |
| Native note-to-note links | Done | Done | Target UUID and display text are preserved. |
| Paragraph links and persistent anchors | Done | Done | Paragraph UUIDs and local anchor resolution are supported. |
| URL preview cards | Done | Done | Native URL cards are decoded and inserted. |
| Native tags | Done | Done | Tag identity, counts, add, replace, and remove are supported. |
| Mentions | Done | Missing | Stored participant identity is rendered; mention creation is not implemented. |
| Photos and images | Done | Done | Metadata, originals, previews, insertion, and export. |
| Videos | Done | Done | Original media and preview frames are available; files can be inserted. |
| PDFs | Done | Done | Original, preview, indexed text, insertion, and export. |
| General file attachments | Done | Done | Original bytes and metadata are preserved. |
| Maps and location cards | Done | Partial | Existing cards are retained; a file or URL can be attached, but native Maps-card construction is absent. |
| Contact cards | Done | Partial | Existing vCards are retained; generic attachment insertion does not create every native contact-card variant. |
| Scanned documents | Done | Missing | Ordered pages, OCR, originals, and PDF export work; document-camera capture is not implemented. |
| Image and PDF markup | Partial | Not possible | Flattened output can be read; Notes does not expose a stable local API for editable markup graphs. |
| Classic drawings and sketches | Done | Not possible | Classic strokes and SVG or raster fallback are readable; no safe native stroke-object constructor is exposed. |
| Modern Paper drawings | Partial | Not possible | Fallback generations and handwriting are readable; the private Paper editing model has no stable checked write path. |
| Audio file attachments | Done | Done | Original audio can be fetched, exported, and inserted. |
| Native audio recordings | Done | Partial | Recording fragments and metadata are decoded; inserting an audio file does not create the full recorder object. |
| Stored audio transcripts | Done | Not possible | Text, timing, speakers, and fragments are decoded; Notes owns transcript generation and storage. |
| Recording summaries and call metadata | Done | Not possible | Stored summaries and call fields are readable; generation is a Notes and system service. |
| Math expressions, results, and graphs | Done | Missing | Inline math objects and alternate text are retained; native calculation-object creation is not implemented. |
| Divider lines | Done | Missing | Divider inline objects are retained; native insertion is not implemented. |
| Pin and unpin | Done | Done | Native pinned state is readable and writable. |
| Locked-note state | Done | Not possible | Locked notes are detected without content access; encryption credentials and key handling are not safely exposed. |
| Share state and participants | Done | Not possible | Participants and permissions are readable; CloudKit invitation and access-right mutation has no stable local contract. |
| Edit an existing shared note | Done | Done | Native writes require an explicit shared-note opt-in and reject read-only or unknown roles. |
| Collaboration activity and changes | Partial | Not possible | Current share metadata is readable; Notes activity UI and notification history are not a stable note data API. |
| Accounts and default location | Done | Partial | Accounts are listed and selected for writes; account creation and settings remain system-owned. |
| Folders and subfolders | Done | Done | Create, rename, move, list, and guarded recursive delete are supported. |
| Recently Deleted | Done | Done | Listing and restore are supported; permanent deletion is intentionally excluded. |
| Smart Folders and rules | Done | Missing | Rules and matching notes are decoded; Smart Folder creation and rule editing are not implemented. |
| Quick Notes | Done | Partial | Quick Notes are detected and their folder can be targeted; hot-corner and capture metadata are app-owned. |
| Folder list and gallery views | Not possible | Not possible | These are Notes.app window states, not persistent note or folder content. |
| Folder sort and group options | Partial | Not possible | NotesCLI can sort query results; it does not read or mutate Notes.app window preferences. |
| Note display order | Done | Partial | Stored display order is read and exported; manual UI reordering is not implemented. |
| Search by title and body | Done | Not possible | Search is implemented; there is no note content to write for this feature. |
| Search filters and Boolean queries | Done | Not possible | Dates, tags, pins, folders, and attachment kinds are queryable. |
| OCR and image labels | Done | Not possible | Stored recognition is decoded and indexed; recognition generation belongs to Notes and Vision services. |
| Handwriting recognition | Done | Not possible | Stored handwriting text is decoded and indexed; recognition generation is system-owned. |
| PDF text search | Done | Not possible | Cached PDF text is indexed; source PDFs remain unchanged. |
| Audio transcript search | Done | Not possible | Stored transcript text is indexed; search has no write operation. |
| Import plain text, HTML, and Markdown | Done | Done | New and existing notes support file, standard input, and Markdown workflows. |
| Export Markdown and HTML | Done | Done | Folder trees and original attachments are supported. |
| Export JSON, NDJSON, and SQLite | Done | Done | Structured and normalized exports are supported. |
| Export PDF, DOCX, RTF, and EPUB | Done | Done | PDF supports combined output; EPUB preserves folder chapters. |
| Export Bear, Joplin, Quiver, TextBundle, and ZIP | Done | Done | Merged export formats are reflected here. |
| Print | Not possible | Not possible | Printing is a Notes.app or system print-panel action with no stable headless Notes API. |
| Widgets | Not possible | Not possible | Widgets are system UI, not note data readable or writable by NotesCLI. |
| Note notifications | Partial | Not possible | Collaboration metadata may be present; delivery and notification settings are system-owned. |
| Notes settings | Partial | Not possible | Some effects are visible in stored data; Notes.app preferences are not a stable supported API. |
| Default account and formatting settings | Partial | Not possible | The effective account can be read; changing Notes defaults is app-owned. |
| Note links and Share-sheet capture | Done | Partial | Deep links and inserted content work; invoking another app's Share sheet is outside the CLI. |
| Open notes, folders, accounts, and attachments | Done | Done | NotesCLI can ask Notes or Finder to reveal the selected object. |
| Sync and upload state | Done | Done | State is readable; writes can request upload and wait for bounded acknowledgement. |
| Version history, diff, undo, and revert | Done | Done | Local snapshots and revision guards support recovery and comparison. |
| Multiple iCloud, local, and IMAP accounts | Done | Done | Reads and supported writes resolve the account and folder explicitly. |

