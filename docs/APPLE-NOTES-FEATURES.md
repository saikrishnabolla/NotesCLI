# Apple Notes feature inventory

Verified on macOS 27.2.1 on 2026-11-14. Apple documents the user-facing features in the [Notes User Guide](https://support.apple.com/guide/notes/welcome/mac), including [formatting](https://support.apple.com/en-ca/guide/notes/apd1955d3b21/mac), [lists](https://support.apple.com/en-ca/guide/notes/apd93c815aa0/mac), [attachments](https://support.apple.com/en-ae/guide/notes/not95edd2813/mac), [sorting and pinning](https://support.apple.com/en-ie/guide/notes/apdb54e469b6/mac), [Smart Folders](https://support.apple.com/en-ph/guide/notes/apd58edc7964/mac), [sharing](https://support.apple.com/en-ie/guide/notes/apda5307056b/mac), and [settings](https://support.apple.com/en-ie/guide/notes/apd97da26aed/mac). Runtime inspection of Notes.app and NotesShared found `ICTTParagraphStyle`, `ICTTFont`, `TTEmphasis`, `NSSuperScript`, `TTColor`, `ICOutlineState`, and their checked setters. Protobuf probes confirmed paragraph fields 1, 2, 3, 4, 6, 7, and 9, plus highlight field 14. The field-14 result agrees with [apple_cloud_notes_parser's schema](https://github.com/threeplanetssoftware/apple_cloud_notes_parser/blob/master/proto/notestore.proto). “Read” and “Write” below describe NotesCLI, not Notes.app.

Read status: 87 Done, 7 Partial, and 2 Not possible. Write status: 71 Done, 13 Partial, and 12 Not possible. The 34 non-Done cells have 20 `apple_blocked`, 8 `needs_fixture`, 2 `partial_impl`, and 4 `not_applicable` reasons. The matrix has 96 rows and no Missing status. `notescli capabilities` and MCP `get_capabilities` use the same feature names and statuses; a literal parity test checks this table against the runtime catalog.

| Feature | Read | Write | Notes |
| --- | --- | --- | --- |
| Title style | Done | Done | The default native engine writes paragraph style 0. Scripting imports `<h1>` as 24px bold body text. |
| Heading style | Done | Done | The default native engine writes paragraph style 1. Scripting imports `<h2>` as 18px bold body text. |
| Subheading style | Done | Done | The default native engine writes paragraph style 2. Scripting imports `<h3>` as bold body text. |
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
| Mentions | Done | Partial | Write reason: `needs_fixture`. `ICInlineAttachment.newMentionAttachmentWithIdentifier:mentionText:userRecordName:note:parentAttachment:` creates mentions in shared notes. NotesCLI requires `--allow-shared`; participant notification has not been tested with a second account. |
| Photos and images | Done | Done | Metadata, originals, previews, insertion, and export. |
| Camera capture | Done | Partial | Write reason: `needs_fixture`. `camera devices`, `camera photo`, `camera scan`, and the matching MCP tools use AVFoundation devices, including an iPhone exposed as a Continuity Camera webcam. They support `--device`, `--delay`, `--count`, and an injected `--source-image`. Camera access runs through the Capability Host when installed; the host and release CLI carry the camera usage text and entitlement. A Continuity Camera webcam is not Notes' iPhone “Scan Documents” action. Runtime inspection found document models, image caches, filters, and a crop editor in DocumentCamera.framework, but no capture controller or headless capture method. Camera scan therefore uses AVFoundation capture followed by Vision edge detection and Core Image correction. Device listing and injected photo and scan writes passed native and SQLite readback on this Mac. Physical capture returned `camera_access_denied` with the System Settings fix, so frame capture and the host permission prompt remain unverified. |
| Editorial SVG and HTML diagrams | Done | Done | Image mode renders through WebKit to a cropped 2x or 3x PNG with recoverable source metadata. Drawing mode converts supported SVG shapes and paths to editable Paper strokes. |
| Videos | Done | Done | Original media and preview frames are available; files can be inserted. |
| PDFs | Done | Done | Original, preview, indexed text, insertion, and export. |
| General file attachments | Done | Done | Original bytes and metadata are preserved. |
| Maps and location cards | Done | Done | `map add` creates an Apple Maps URL attachment, calls the checked `addLocationIfNeeded` selector, and verifies the native `ICAttachmentMapModel` and stored location through fresh SQLite readback. URLs must use `https://maps.apple.com`. |
| Contact cards | Done | Not possible | Write reason: `apple_blocked`. macOS 27.2.1 (26B131) evidence: a live `public.vcard` insert rendered as `ICAttachmentTypeGeneric`, and runtime inspection found no checked contact-card constructor. |
| Scanned documents | Done | Partial | Write reason: `partial_impl`. `scan add` and `scan append` write ordered native `com.apple.notes.gallery` pages. Page state, all five Notes filters, rotation, crop, move, delete, complete-order batch reorder, page replacement, and renewed perspective correction use checked native selectors with fresh native and SQLite readback. Vision detects edges and Core Image applies perspective correction. History restores scan markup and checks each page with a 256×256 visual comparison before committing the ordered transaction. A snapshot with no crop is refused when the current page has a crop because the checked runtime has no crop-clear operation. Crops and correction refuse rotated or marked-up pages. Notes.app on this Mac reopened the disposable correction fixture and rendered both pages. Crop clearing, iPhone Scan Documents, and exported-PDF proof remain absent. |
| Image and PDF markup | Done | Partial | Write reason: `needs_fixture`. Notes' image Markup editor still writes AnnotationKit archives inside the image; standalone toolbar drawings use PaperKit. `attachment markup` can inspect, export, set, copy, clear, list, add, remove, and render text boxes, rectangles, ovals, arrows, lines, ink, and highlights. A disposable live test added a shape, read it through native and SQLite-backed paths, rendered it to PNG, copied it, and cleared it. Notes.app select-and-move editing of CLI-added shapes remains unverified. |
| Classic drawings and sketches | Done | Done | NotesCLI decodes classic drawing strokes and creates editable legacy drawing attachments from validated stroke records. History restoration recreates and verifies the stroke payload through fresh reads. |
| Modern Paper drawings | Done | Done | `ICPaperAttachmentCreationHelper.createSystemPaperAttachmentWithPKDrawing:inNote:` creates editable `com.apple.paper` attachments. `ICSystemPaperDrawingsHelper.drawingsForAttachment:` returns their PencilKit strokes for SVG and PNG export. Native readback compares each stroke's ink, color, width, and points with the input, allowing the single shift Notes applies to the whole drawing; SQLite readback checks attachment identity and placement. Creation and rendering in Notes.app on the Mac are verified. A drawing created by notescli was edited with Apple Pencil on iPad, synced back, and read with every original and new stroke. |
| Audio file attachments | Done | Done | Original audio can be fetched, exported, and inserted. |
| Native audio recordings | Done | Done | `recording add` and `recording create` convert input with AVFoundation, then use checked `ICAttachmentAudioModel` selectors to create the recorder container, fragment child, duration, and mergeable recording data. Fresh SQLite readback verifies the graph and media hash. |
| Stored audio transcripts | Done | Done | `recording transcribe` transcribes a recording on device and stores the result in the note; `recording transcribe-file` writes timed on-device Speech results without opening Notes. Verified live on macOS 27. `--transcript-file` stores those segments as native `ICTTTranscriptSegment` objects in the recording CRDT. `recording transcript` reads Notes transcripts as text, SRT, VTT, or JSON. |
| Recording summaries and call metadata | Done | Partial | Write reason: `needs_fixture`. `recording clear-summary` and MCP `recording_summary_clear` delete an Apple-generated summary while preserving recording and call metadata. This Mac has no recording with a generated summary. |
| Math expressions, results, and graphs | Done | Partial | Write reason: `apple_blocked`. macOS 27.2.1 (26B131) evidence: checked native insertion and Calculate cover stored expressions and plain-text results, while interactive recognition and graph rendering remain inside Notes.app. |
| Divider lines | Done | Done | `newDividerLineAttachmentWithIdentifier:note:parentAttachment:` creates the native divider and exact native and SQLite readback verifies it. |
| Pin and unpin | Done | Done | Native pinned state is readable and writable. |
| Locked-note state | Done | Not possible | Write reason: `apple_blocked`. macOS 27.2.1 (26B131) evidence: `ICNote` exposes lock-state getters, but runtime inspection found no authenticated unlock or key-management write contract for a background client. |
| Share state and participants | Done | Not possible | Write reason: `apple_blocked`. macOS 27.2.1 (26B131) evidence: share and participant objects expose read properties, but runtime selector inspection found no stable invitation, removal, or access-right mutation contract. |
| Edit an existing shared note | Partial | Partial | Read/write reason: `needs_fixture`. Native writes require explicit opt-in and reject read-only or unknown roles. Owner, read-write participant, read-only participant, and concurrent-edit fixtures have not run. |
| Collaboration activity and changes | Partial | Not possible | Read reason: `needs_fixture`; write reason: `apple_blocked`. `collaboration activity` and MCP `collaboration_activity` export stored activity as bounded, hashed raw data, but no activity-bearing fixture has run. macOS 27.2.1 (26B131) evidence: collaboration records are managed by Notes and CloudKit, and runtime inspection found no supported mutation contract. |
| Accounts and default location | Done | Partial | Write reason: `apple_blocked`. macOS 27.2.1 (26B131) evidence: NotesCLI can select the default account, but account creation and account settings remain system-owned. |
| Folders and subfolders | Done | Done | Create, rename, move, list, and guarded recursive delete are supported. |
| Recently Deleted | Done | Done | Listing and restore are supported; permanent deletion is intentionally excluded. |
| Smart Folders and rules | Done | Done | Rules support `type` around one rule; `and`, `or`, and `not`; Boolean note flags; tags, folders, participants, attachment sections 1 through 7, and absolute or relative creation and modification dates. A `type` rule cannot have siblings. Native writes compare exact `smartFolderQueryJSON` readback. |
| Quick Notes | Done | Partial | Write reason: `apple_blocked`. macOS 27.2.1 (26B131) evidence: NotesCLI can target the Quick Notes folder, but hot-corner and capture metadata are owned by Notes.app and system UI. |
| Folder list and gallery views | Partial | Not possible | Read/write reason: `apple_blocked`. macOS 27.2.1 (26B131) evidence: NotesCLI can read only Notes' last-saved `windowStateArchive`, not the live window; inspected writes use Notes.app menu and link actions. |
| Folder sort options | Done | Done | `folder sort` reads and writes `ICFolder.customNoteSortType`. Live probes confirmed modified 10/11, created 20/21, and title 30/31. |
| Folder grouping by date | Done | Done | `folder group-by-date` reads `isShowingDateHeaders` and writes through `applyDateHeadersType:`. Native and SQLite readback verify the setting. The journal preserves inherited, off, and on as separate states. |
| Note display order | Done | Partial | Write reason: `apple_blocked`. macOS 27.2.1 (26B131) evidence: SQLite has `ZSORTORDER`, but runtime inspection found no checked `ICNote.setSortOrder:` selector. |
| Search by title and body | Done | Not possible | Write reason: `not_applicable`. Search is a read operation and has no persistent object to write. |
| Search filters and Boolean queries | Done | Not possible | Write reason: `not_applicable`. Filters and Boolean queries are read predicates, not writable Notes objects. |
| OCR and image labels | Done | Done | Stored OCR, image labels, summaries, and version fields are readable. `ocr set`, `image-labels set`, MCP `ocr_set`, and MCP `image_labels_set` replace or clear the stored values. An opt-in disposable live test verifies exact native and SQLite readback plus snapshot restoration; the MCP protocol test verifies dispatch and journaling. `ocr` and MCP `ocr_attachment` can also recognize a downloaded image without changing Notes. |
| Handwriting recognition | Done | Done | `handwriting recognize --persist` runs Apple's checked recognizer and saves its text. `handwriting set` replaces or clears the stored handwriting summary. Native and SQLite readback verify the saved value. |
| PDF text search | Done | Not possible | Write reason: `not_applicable`. PDF search reads Apple's cached index; there is no user-facing value to write. |
| Audio transcript search | Done | Not possible | Write reason: `not_applicable`. Transcript search is a read operation and has no persistent search object to write. |
| Import plain text, HTML, and Markdown | Done | Done | New and existing notes support file, standard input, and Markdown workflows. |
| Export Markdown and HTML | Done | Done | Folder trees and original attachments are supported. |
| Export JSON, NDJSON, and SQLite | Done | Done | Structured and normalized exports are supported. |
| Export PDF, DOCX, RTF, and EPUB | Done | Done | PDF supports combined output; EPUB preserves folder chapters. |
| Export Bear, Joplin, Quiver, TextBundle, and ZIP | Done | Done | Merged export formats are reflected here. |
| Print | Not possible | Not possible | Read/write reason: `apple_blocked`. macOS 27.2.1 (26B131) evidence: Notes.app exposes print-panel UI actions but no headless NotesShared print contract. |
| Widgets | Not possible | Not possible | Read/write reason: `apple_blocked`. macOS 27.2.1 (26B131) evidence: widget state lives in system UI extensions, and NotesShared exposes no widget state property or mutation selector. |
| Note notifications | Partial | Not possible | Read/write reason: `apple_blocked`. macOS 27.2.1 (26B131) evidence: `ICCloudNotificationsController updateSubscriptionPreferenceForMentionNotifications:forAccount:` changes a CloudKit subscription using Notes' entitlements, not a writable preference. |
| Notes settings | Partial | Partial | Read/write reason: `apple_blocked`. `settings show` and MCP `get_notes_settings` cover global sort, date grouping, text size, Quick Note resume, tag conversion, paragraph style, checklist sorting, query grouping, Markdown formatting, dark backgrounds, and note counts. macOS 27.2.1 (26B131) evidence: the remaining settings require account lifecycle, locked-note authentication, or Notes-entitled CloudKit access. |
| Default account | Done | Done | `accounts` reads the default account. `accounts --set-default` writes and verifies `DefaultNotesAccount` in Notes' group-container preferences file. NotesShared's own default-account API resolves to the unsandboxed shadow file `~/Library/Preferences/group.com.apple.notes.plist` in NotesCLI's process, which Notes never reads, so it is used only as a fallback when no stored value exists and the shadow file has none. |
| Default paragraph style | Done | Done | `settings default-style` reads and writes `TTTextControllerNoteDefaultNamedStyleKey` in Notes' app-group preferences file, with `ICTextStyle.noteDefaultNamedStyle` as the default-value fallback. It supports the Notes settings choices title, heading, subheading, and body, verifies exact readback, and records the previous value in the journal. |
| Note links and Share-sheet capture | Done | Done | `link capture` and MCP `link_capture` create Notes' native Synapse web attachment with `SYContentItem` and `addSynapseLinkAttachmentWithContentItem:`. Native decode, one body marker, nonempty SQLite Synapse data, idempotent replay, and exact undo were verified live. Opening another app's Share-sheet UI remains outside the CLI. |
| Open notes, folders, accounts, and attachments | Done | Done | NotesCLI can ask Notes or Finder to reveal the selected object. |
| Sync and upload state | Done | Done | State is readable; writes can request upload and wait for bounded acknowledgement. |
| Version history, diff, undo, and revert | Partial | Partial | Read/write reason: `apple_blocked`. NotesCLI keeps exact snapshots for its own writes. macOS 27.2.1 (26B131) evidence: Apple exposes no complete Notes version-history API for earlier edits. Native restore verifies supported content through fresh native and database reads; unknown attachment graphs and device-key/passcode V2 notes remain unavailable. |
| Multiple iCloud, local, and IMAP accounts | Partial | Partial | Read reason: `partial_impl`; write reason: `needs_fixture`. The full-fidelity reader maps `ZACCOUNTTYPE=3` to IMAP but opens only `NoteStore.sqlite`; account-aware writes route through Notes.app. This Mac's separate `NotesV7.storedata` has one enabled LocalAccount row, no notes, and no IMAP account. Current IMAP placement and local or IMAP writes remain unproved. |

## Live proof still required

These live tests compile but have not run with the required fixtures.

1. In Notes, open Settings and tick **Enable On My Mac account** if it is off. Do not enable it through private APIs.
2. Sign in to iCloud.com with a second free Apple ID. Accept a read-write share from this Mac.
3. Prepare three disposable notes whose titles start with `notescli-test-`: one owned by this Mac and shared read-write, one owned by the second account and shared read-write to this Mac, and one owned by the second account and shared read-only to this Mac.
4. Run the command below. When the test prints a unique concurrent marker, append it to the owner note from the second account on iCloud.com.

```sh
NOTESCLI_LIVE_ACCOUNT_TESTS=1 NOTESCLI_LIVE_SHARED_TESTS=1 NOTESCLI_SHARED_NOTE_ID=OWNER_NOTE_ID NOTESCLI_SHARED_READ_WRITE_NOTE_ID=PARTICIPANT_NOTE_ID NOTESCLI_SHARED_READ_ONLY_NOTE_ID=READ_ONLY_NOTE_ID swift test --filter LiveAccountAndSharedTests
```

