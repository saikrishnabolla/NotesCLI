import ArgumentParser
import Darwin
import Foundation
import NotesCore
import NotesNative
import NotesSafety
import NotesStore

struct ImportCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "import",
        abstract: "Preview and import documents or original files into Apple Notes.")
    enum Mode: String, ExpressibleByArgument { case combined, separate }
    @OptionGroup var options: GlobalOptions
    @OptionGroup var write: WriteOptions
    @Option(help: "Destination folder ID or unambiguous folder path.") var folder: String
    @Option(help: "Create a single note or one note per file.") var mode: Mode = .combined
    @Option var title: String?
    @Option(help: "Attach the selected files below the title of an existing note.") var into: String?
    @Option(help: "Require the plan token returned by --dry-run.") var expectPlan: String?
    @Option(help: "After checking Notes manually, acknowledge an uncertain journal operation before retrying.") var retryAfterReview: String?
    @Argument(help: "Files or folders; put -- before paths that begin with a dash.") var paths: [String]

    struct Preview: Codable {
        var items: [Item]
        var warnings: [String]
        var token: String
        struct Item: Codable {
            var title: String
            var attachmentCount: Int
            var tableCount: Int
            var warnings: [String]
            var duplicate: String?
            var excerpt: String?
            var blocked: Bool
            var files: [String]
        }
    }
    struct Receipt: Encodable {
        var notes: [Item]
        var warnings: [String]
        struct Item: Encodable {
            var title: String
            var id: String?
            var link: String?
            var localVerification: String
            var cloudSync: String
            var message: String?
        }
    }
    private struct Source {
        var url: URL
        var root: URL
    }
    private struct Item {
        var title: String
        var body: String
        var attachments: [URL]
        var assets: [URL]
        var warnings: [String]
        var sourceIdentity = ""
        var fingerprint = ""
        var existing: NoteSummary?
        var overlap: String?
        var unresolvedJournalID: String?
    }
    private static let textExtensions: Set<String> = ["md", "markdown", "mdown", "html", "htm", "txt", "text"]
    private static let maxFiles = 100
    private static let maxBatchBytes = 2 * 1024 * 1024 * 1024

    func validate() throws {
        guard !paths.isEmpty else { throw ValidationError("Choose at least one file or folder.") }
        guard mode != .separate || (into == nil && title == nil) else {
            throw ValidationError("--title and --into require combined mode.")
        }
        guard title == nil || into == nil else { throw ValidationError("Choose --title or --into, not both.") }
        guard retryAfterReview == nil || (expectPlan != nil && !write.dryRun) else {
            throw ValidationError("--retry-after-review requires a fresh --expect-plan token.")
        }
        guard title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != true else {
            throw ValidationError("The title cannot be empty.")
        }
        if let title, title.contains(where: \.isNewline) { throw ValidationError("Use a single-line title.") }
    }

    func run() throws {
        let backend = try write.dryRun ? options.backends() : options.writable()
        let importLock = write.dryRun ? nil : try Self.acquireWriteLock()
        defer { if let importLock { _ = close(importLock) } }
        guard backend.fidelity == .full else {
            throw NotesError("full_disk_access_denied", "Grant Notes CLI Full Disk Access to verify an import.")
        }
        if !write.dryRun {
            _ = try UnifiedNative.engine(options, scriptingAvailable: false, fake: backend.isFake)
        }
        guard let destination = try SafetyExecutor.folder(folder, reader: backend.reader),
              !destination.isSmartFolder, !destination.isRecentlyDeleted else {
            throw NotesError("import_folder_not_writable", "Choose a regular Notes folder.")
        }
        try SafetyExecutor.allowlist(write).require(destination.path)
        let target = try into.map { try backend.reader.note($0) }
        if let target {
            guard target.summary.folderID == destination.id, target.document != nil, !target.summary.isDeleted,
                  !target.summary.isLocked else {
                throw NotesError("import_target_invalid", "Choose an unlocked note in the selected folder.")
            }
            if target.summary.isShared == true && !write.allowShared {
                throw NotesError("shared_write_refused", "The note is shared. Pass --allow-shared to confirm the write.")
            }
        }

        let (sources, inputWarnings) = try listSources()
        var items = try makeItems(sources, target: target)
        let pathsToHash = Set(items.flatMap { $0.attachments + $0.assets })
        guard pathsToHash.count <= Self.maxFiles else {
            throw NotesError("import_too_many_files", "Import at most \(Self.maxFiles) files and inline assets at a time.")
        }
        var hashes: [URL: String] = [:]
        var bytes = 0
        for file in pathsToHash.sorted(by: { $0.path < $1.path }) {
            let validated = try InputFile.validated(file, kind: "attachment", maxBytes: FrozenAttachmentInput.maxBytes)
            guard validated.path == file.path else { throw NotesError("import_source_changed", "An attachment path changed.") }
            let info = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard info.isRegularFile == true, let size = info.fileSize, size > 0 else {
                throw NotesError("invalid_file", "“\(file.lastPathComponent)” is not a nonempty regular file.")
            }
            bytes += size
            guard bytes <= Self.maxBatchBytes else {
                throw NotesError("import_batch_too_large", "Attachments in one import are limited to 2 GB total.")
            }
            hashes[file] = try FrozenAttachmentInput.hash(file: file, maxBytes: FrozenAttachmentInput.maxBytes)
        }
        let existing = try backend.reader.notes(NoteQuery(folder: destination.id))
        let byID = Dictionary(existing.map { ($0.id.uuid, $0) }, uniquingKeysWith: { first, _ in first })
        let history = try WriteJournal.openReadOnlyIfExists()?.list(limit: Int(Int32.max), operation: "importDocument") ?? []
        var previous: [String: [(NoteSummary, String)]] = [:]
        var unresolved: [String: String] = [:]
        var completedKeys = Set<String>()
        for entry in history where entry.operation == "importDocument" {
            guard let data = try? JSONDecoder().decode([String: String].self, from: entry.arguments),
                  let key = data["fingerprint"] else { continue }
            if entry.outcome == .verified {
                completedKeys.insert(key)
                if let id = entry.noteID, let note = byID[id], let rev = data["import_revision"] {
                    previous[key, default: []].append((note, rev))
                }
            } else if [.started, .unknown, .unverified].contains(entry.outcome),
                      !completedKeys.contains(key), unresolved[key] == nil {
                unresolved[key] = entry.id
            }
        }
        for i in items.indices {
            let item = items[i]
            let keys = (item.attachments + item.assets).map { [$0.lastPathComponent, hashes[$0] ?? ""] }
            let fingerprint = FrozenAttachmentInput.hash(try JSONEncoder().encode(
                [[destination.id, target?.summary.id.uuid ?? "", item.title, item.body, item.sourceIdentity]] + keys
            ))
            items[i].fingerprint = fingerprint
            if let matches = previous[fingerprint] {
                for (summary, revision) in matches {
                    if let current = try? backend.reader.note(summary.id.uuid), NoteRevision.importValue(current) == revision {
                        items[i].existing = summary
                        items[i].overlap = "Exact repeat of an earlier import. It will be skipped."
                        break
                    }
                }
                if items[i].existing == nil {
                    items[i].overlap = "These files were imported before, but the earlier note has changed."
                }
            }
            if let operation = unresolved[fingerprint], items[i].existing == nil {
                items[i].unresolvedJournalID = operation
                items[i].overlap = "An earlier import was not verified (operation \(operation)). Check Notes before retrying."
            }
            if items[i].overlap == nil {
                if let target {
                    let names = Set(item.attachments.map(\.lastPathComponent))
                    if target.attachments.contains(where: { names.contains($0.filename ?? $0.title ?? "") }) {
                        items[i].overlap = "The note already contains an attachment with the same name. Review before attaching."
                    }
                } else if let match = existing.first(where: { Self.overlaps(item, $0) }) {
                    items[i].overlap = "Possible overlap with “\(match.title)”. The existing note will not be changed."
                }
            }
            if items[i].overlap == nil, items.prefix(i).contains(where: { Self.normalize($0.title) == Self.normalize(item.title) }) {
                items[i].overlap = "Another item in this batch has the same title."
            }
        }
        let previewItems = items.map { item -> Preview.Item in
            let doc = NotesMarkdownDocument(parsing: item.body)
            let excerpt = doc.paragraphs.filter { $0.table == nil && !$0.plainText.isEmpty }
                .prefix(4).map(\.plainText).joined(separator: "\n\n")
            return Preview.Item(title: item.title, attachmentCount: item.attachments.count + item.assets.count,
                                tableCount: doc.paragraphs.filter { $0.table != nil }.count, warnings: item.warnings,
                                duplicate: item.overlap, excerpt: excerpt.isEmpty ? nil : String(excerpt.prefix(720)),
                                blocked: item.unresolvedJournalID != nil,
                                files: (item.assets + item.attachments).map(\.lastPathComponent))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var key = try encoder.encode(previewItems)
        key.append(try encoder.encode(inputWarnings + items.map(\.fingerprint) + items.map { $0.existing?.id.uuid ?? "" } +
            [target.map(NoteRevision.importValue) ?? "", destination.path.joined(separator: "/")]))
        let preview = Preview(items: previewItems, warnings: inputWarnings, token: FrozenAttachmentInput.hash(key))
        if write.dryRun {
            if options.json { try Output.json(preview) }
            else {
                Output.table(["NOTE", "FILES", "TABLES"], preview.items.map { [$0.title, String($0.attachmentCount), String($0.tableCount)] })
                for message in inputWarnings + preview.items.flatMap({ $0.warnings + [$0.duplicate].compactMap { $0 } }) {
                    Output.error(message)
                }
            }
            return
        }
        if let expectPlan, expectPlan != preview.token {
            throw NotesError("import_plan_changed", "The files, note, or destination changed after preview. Preview again.")
        }
        if let unresolved = items.compactMap(\.unresolvedJournalID).first(where: { $0 != retryAfterReview }) {
            throw NotesError("import_previous_write_unverified",
                "A previous import with operation ID \(unresolved) was not verified. Inspect Notes before retrying.",
                hint: "Only if the earlier write did not take effect, preview again and use --retry-after-review \(unresolved).")
        }
        if let retryAfterReview, !items.contains(where: { $0.unresolvedJournalID == retryAfterReview }) {
            throw NotesError("invalid_import_retry", "The operation ID does not match this import plan.")
        }
        if expectPlan == nil, items.contains(where: { $0.overlap != nil && $0.existing == nil }) {
            throw NotesError("import_overlap_review_required", "Possible overlap. Run --dry-run and review the plan, then pass --expect-plan with its token.")
        }
        var receipts: [Receipt.Item] = []
        var writeStarted: [String: Date] = [:]
        for (i, item) in items.enumerated() {
            if let existing = item.existing {
                receipts.append(.init(title: item.title, id: existing.id.uuid, link: existing.deepLink,
                                      localVerification: "already_imported", cloudSync: "not_checked", message: item.overlap))
                continue
            }
            let start = Date().addingTimeInterval(-1)
            let result = perform(item, index: i, folder: destination, target: target, hashes: hashes, backend: backend)
            if let id = result.id, result.localVerification == "verified" { writeStarted[id] = start }
            receipts.append(result)
            if result.localVerification == "unknown" || result.localVerification == "unverified" {
                break // Resolve an ambiguous write before continuing.
            }
        }
        if write.waitSync && !backend.isFake {
            let deadline = Date().addingTimeInterval(write.syncTimeout)
            for i in receipts.indices {
                guard let id = receipts[i].id, let start = writeStarted[id] else { continue }
                let sync = try? NoteSyncWaiter.wait(noteID: id, modifiedAfter: start,
                                                   timeout: max(0, deadline.timeIntervalSinceNow))
                receipts[i].cloudSync = sync == true ? "confirmed" : "unconfirmed"
            }
        }
        let receipt = Receipt(notes: receipts, warnings: Array(Set(inputWarnings + items.flatMap(\.warnings))).sorted())
        if options.json { try Output.json(receipt) }
        else {
            Output.table(["NOTE", "LOCAL", "ICLOUD"], receipt.notes.map { [$0.title, $0.localVerification, $0.cloudSync] })
            for warning in receipt.warnings + receipts.compactMap(\.message) { Output.error(warning) }
        }
        if receipts.contains(where: { !["verified", "already_imported"].contains($0.localVerification) }) {
            throw ExitCode.failure
        }
    }

    private func listSources() throws -> ([Source], [String]) {
        var found: [Source] = []
        var seen = Set<URL>()
        var warnings: [String] = []
        let manager = FileManager.default
        func add(_ url: URL, root: URL) throws {
            let file = url.standardizedFileURL.resolvingSymlinksInPath()
            guard file.path.hasPrefix(root.path.hasSuffix("/") ? root.path : root.path + "/"),
                  InputFile.isAllowed(file.path) else {
                throw NotesError("input_path_refused", "A selected file points outside its import folder.")
            }
            guard seen.insert(file).inserted else { return }
            guard found.count < Self.maxFiles else {
                throw NotesError("import_too_many_files", "Import at most \(Self.maxFiles) files at a time.")
            }
            found.append(Source(url: file, root: root))
        }
        for path in paths {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
                .standardizedFileURL.resolvingSymlinksInPath()
            guard InputFile.isAllowed(url.path) else {
                throw NotesError("input_path_refused", "Select files or folders outside Library and hidden folders.")
            }
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isPackageKey])
            if values.isDirectory == true, values.isPackage != true {
                let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .isPackageKey]
                var unreadable = false
                guard let walk = manager.enumerator(at: url, includingPropertiesForKeys: Array(keys),
                    options: [.skipsHiddenFiles, .skipsPackageDescendants],
                    errorHandler: { _, _ in unreadable = true; return false }) else {
                    throw NotesError("invalid_file", "Cannot open “\(url.lastPathComponent)”.")
                }
                var files: [URL] = []
                for case let child as URL in walk {
                    let values = try child.resourceValues(forKeys: keys)
                    if values.isSymbolicLink == true || values.isPackage == true {
                        walk.skipDescendants()
                        warnings.append("Links and app packages inside folders are skipped.")
                    } else if values.isRegularFile == true {
                        files.append(child)
                        guard files.count <= Self.maxFiles else {
                            throw NotesError("import_too_many_files", "Import at most \(Self.maxFiles) files at a time.")
                        }
                    }
                }
                guard !unreadable else { throw NotesError("invalid_file", "Part of “\(url.lastPathComponent)” could not be read.") }
                if files.isEmpty { warnings.append("“\(url.lastPathComponent)” has no visible files.") }
                for child in files.sorted(by: { $0.path.localizedStandardCompare($1.path) == .orderedAscending }) {
                    try add(child, root: url)
                }
            } else if values.isRegularFile == true {
                try add(url, root: url.deletingLastPathComponent())
            } else {
                throw NotesError("invalid_file", "“\(url.lastPathComponent)” is not a regular file or folder.")
            }
        }
        guard !found.isEmpty else { throw NotesError("empty_import", "No importable files were found.") }
        return (found, Array(Set(warnings)).sorted())
    }

    private func makeItems(_ sources: [Source], target: Note?) throws -> [Item] {
        if let target {
            return [Item(title: target.summary.title, body: "", attachments: sources.map(\.url), assets: [], warnings: [])]
        }
        var items: [Item] = []
        var textBytes = 0
        for source in sources {
            let url = source.url
            let ext = url.pathExtension.lowercased()
            let basename = url.deletingPathExtension().lastPathComponent
            guard Self.textExtensions.contains(ext) else {
                items.append(Item(title: Self.cleanTitle(basename), body: "", attachments: [url], assets: [], warnings: [],
                                  sourceIdentity: mode == .separate ? url.path : ""))
                continue
            }
            let raw = try InputFile.readImportText(url)
            textBytes += raw.utf8.count
            guard textBytes <= InputFile.maxTextBytes else {
                throw NotesError("import_text_too_large", "The source documents exceed 20 MB in total.")
            }
            let html = ["html", "htm"].contains(ext) ? try HTMLNoteImport.convert(raw) : nil
            let prepared = NotesImportFormatting(html?.markdown ?? raw, relativeTo: url.deletingLastPathComponent(),
                allowedRoot: source.root, attachmentLimit: FrozenAttachmentInput.maxBytes, recognizedAsPlainText: ["txt", "text"].contains(ext))
            let htmlWarnings = (html?.warnings ?? []).filter { $0 != HTMLNoteImport.uncheckedImagesWarning }
            items.append(Item(title: Self.cleanTitle(prepared.title ?? html?.title ?? basename), body: prepared.markdown,
                              attachments: [], assets: prepared.assetFiles,
                              warnings: Array(Set(htmlWarnings + prepared.warnings)).sorted(),
                              sourceIdentity: mode == .separate ? url.path : ""))
        }
        if mode == .separate { return items }
        let inline = Set(items.flatMap(\.assets))
        items.removeAll { $0.body.isEmpty && $0.attachments.count == 1 && inline.contains($0.attachments[0]) }
        if items.count == 1 {
            items[0].title = title.map(Self.cleanTitle) ?? items[0].title
            return items
        }
        let documents = items.filter { $0.attachments.isEmpty }
        let fallback = URL(fileURLWithPath: paths[0]).lastPathComponent
        let name = title.map(Self.cleanTitle) ?? (documents.count == 1 ? documents[0].title : Self.cleanTitle(fallback + " — Import"))
        let spacer = "\n\n<!-- notescli-empty-paragraph:0:0 -->\n\n"
        let sections = documents.map {
            "## " + $0.title.replacingOccurrences(of: #"([\\`*_\[\]<>#])"#, with: #"\\$1"#, options: .regularExpression) + "\n\n" + $0.body
        }
        let body = documents.count == 1 ? documents[0].body : sections.joined(separator: spacer)
        if documents.count > 1 {
            let singleSpacer = NotesMarkdownDocument(parsing: spacer).paragraphs
            let expected = sections.enumerated().flatMap { index, section in
                (index == 0 ? [] : singleSpacer) + NotesMarkdownDocument(parsing: section).paragraphs
            }
            guard NotesMarkdownDocument(parsing: body).paragraphs == expected else {
                throw NotesError("import_document_boundary",
                    "Combining these documents would change their formatting or links. Import them as separate notes.")
            }
        }
        return [Item(title: name, body: body, attachments: items.flatMap(\.attachments), assets: items.flatMap(\.assets),
                     warnings: Array(Set(items.flatMap(\.warnings))).sorted())]
    }

    private func perform(_ item: Item, index: Int, folder: Folder, target: Note?, hashes: [URL: String],
                         backend: Backends) -> Receipt.Item {
        do {
            var controls = write
            controls.waitSync = false // Verify the complete batch before waiting on iCloud.
            if let batchKey = write.idempotencyKey { controls.idempotencyKey = "\(batchKey):\(index)" }
            let refreshed = try backend.isFake ? backend.reader : SQLiteNotesStore(refresh: true)
            let currentFolder = try SafetyExecutor.folder(folder.id, reader: refreshed)
            guard currentFolder?.path == folder.path, currentFolder?.isRecentlyDeleted == false else {
                throw NotesError("import_plan_changed", "The destination changed during import.")
            }
            let current = try target.map { try refreshed.note($0.summary.id.uuid) }
            if let current, current.summary.folderID != folder.id {
                throw NotesError("import_plan_changed", "The target note moved during import.")
            }
            var noteID = target?.summary.id.uuid
            let plan = DryRunPlan(operation: "importDocument", target: item.title,
                                  arguments: ["folder": folder.id], resultingHTML: nil, engine: "native")
            let arguments = ["folder": folder.id, "fingerprint": item.fingerprint, "title": item.title]
            let result = try SafetyExecutor.run(options: controls, operation: "importDocument", arguments: arguments,
                note: current, allowedPaths: [folder.path], plan: plan,
                finishArguments: {
                    guard !backend.isFake, let id = noteID,
                          let note = try? SQLiteNotesStore(refresh: true).note(id) else { return [:] }
                    return ["post_revision": ConcurrencyGuard.revision(note), "import_revision": NoteRevision.importValue(note)]
                }) {
                    if backend.isFake {
                        guard current == nil && item.assets.isEmpty && item.attachments.isEmpty else {
                            throw NotesError("fake_import_unsupported", "The fake backend does not store original attachment files.")
                        }
                        return try backend.writer().createNote(title: item.title, markdown: item.body, folder: folder.id)
                    }
                    let files = try item.attachments.map { url in
                        let frozen = try FrozenAttachmentInput(file: url)
                        guard hashes[url] == frozen.sha256 else {
                            throw NotesError("import_source_changed", "“\(url.lastPathComponent)” changed after preview.")
                        }
                        return frozen
                    }
                    let assets = Dictionary(item.assets.compactMap { url in hashes[url].map { (url.path, $0) } },
                                            uniquingKeysWith: { first, _ in first })
                    let expectedDestination = NativeImportDestination(folderID: folder.id, folderPath: folder.path,
                        noteRevision: target.map(NoteRevision.importValue))
                    let input = NativeMarkdownInput(source: item.body, trailingAttachments: files,
                        expectedAssetHashes: assets, importDestination: expectedDestination, renderDiagrams: false)
                    let value: WriteResult
                    if let current {
                        value = try NativeNotesWriter().prependMarkdown(current.summary.id.uuid, input: input,
                                                                        allowShared: controls.allowShared).writeResult
                    } else {
                        value = try NativeNotesWriter().createNote(title: item.title, input: input, folder: folder.id,
                                                                   allowShared: controls.allowShared).write.writeResult
                    }
                    noteID = value.noteID?.uuid
                    return value
                }
            guard let result else { throw NotesError("import_no_result", "The import did not return a write result.") }
            let id = result.noteID?.uuid
            let link = id.flatMap { $0.isEmpty ? nil : "applenotes://showNote?identifier=\($0)" }
            return .init(title: item.title, id: id, link: link, localVerification: result.outcome.rawValue,
                         cloudSync: "not_checked", message: result.message)
        } catch {
            return .init(title: item.title, localVerification: "failed", cloudSync: "not_checked",
                         message: (error as? NotesError)?.message ?? error.localizedDescription)
        }
    }

    private static func cleanTitle(_ value: String) -> String {
        let name = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return name.isEmpty ? "Imported Note" : String(name.prefix(500))
    }

    private static func acquireWriteLock() throws -> Int32 {
        let support = NotesSafetyPaths.applicationSupport
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = open(support.appendingPathComponent("import.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw NotesError("import_lock_failed", "Could not open the import lock.") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            _ = close(fd)
            throw NotesError("import_in_progress", "Another import is writing to Notes. Wait for it to finish, then preview again.")
        }
        return fd
    }

    private static func normalize(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: " ")
    }

    private static func overlaps(_ item: Item, _ note: NoteSummary) -> Bool {
        let left = normalize(item.title), right = normalize(note.title)
        if left == right { return true }
        let a = Set(left.split(separator: " ")), b = Set(right.split(separator: " "))
        if min(a.count, b.count) >= 3 && a.intersection(b).count * 4 >= a.union(b).count * 3 { return true }
        let snippet = normalize(note.snippet)
        return snippet.split(separator: " ").count >= 12 && normalize(item.body).contains(snippet)
    }
}
