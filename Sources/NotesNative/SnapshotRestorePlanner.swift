import Foundation
import NotesCore
import UniformTypeIdentifiers

struct SnapshotRestoreDigest: Equatable, Sendable {
    var sha256: String
    var byteCount: Int
}

/// Evidence about one stored payload of an existing attachment row.
/// `notCollected` means the caller did not read it; `absent` means the row has no such payload.
enum SnapshotRestoreDigestEvidence: Equatable, Sendable {
    case notCollected
    case absent
    case present(SnapshotRestoreDigest)
}

/// Current-state evidence for an existing row. Each digest must be computed the same way the
/// snapshot archive computed the matching `SnapshotAttachmentMaterial` field.
struct SnapshotRestoreExistingEvidence: Equatable, Sendable {
    var blob: SnapshotRestoreDigestEvidence = .notCollected
    var paperBundle: SnapshotRestoreDigestEvidence = .notCollected
    var synapse: SnapshotRestoreDigestEvidence = .notCollected
    var linkMetadata: SnapshotRestoreDigestEvidence = .notCollected
    var scanMarkup: SnapshotRestoreDigestEvidence = .notCollected
    /// Stored child order (gallery pages or recording fragments). `nil` means not collected.
    var orderedChildIDs: [String]?
}

struct SnapshotRestoreExistingAttachment: Equatable, Sendable {
    var id: String
    var typeUTI: String
    var parentID: String?
    var belongsToTargetNote: Bool
    var isMarkedForDeletion: Bool
    var evidence: SnapshotRestoreExistingEvidence

    init(id: String, typeUTI: String, parentID: String? = nil,
         belongsToTargetNote: Bool = true, isMarkedForDeletion: Bool,
         evidence: SnapshotRestoreExistingEvidence = SnapshotRestoreExistingEvidence()) {
        self.id = id
        self.typeUTI = typeUTI
        self.parentID = parentID
        self.belongsToTargetNote = belongsToTargetNote
        self.isMarkedForDeletion = isMarkedForDeletion
        self.evidence = evidence
    }
}

enum SnapshotRestoreRefusalReason: String, Equatable, Sendable {
    case invalidSnapshot
    case idCollision
    case typeMismatch
    case nestedAttachment
    case parentChildTopology
    case missingMaterial
    case missingBlob
    case unsupportedInline
    case unsupportedTable
    case unsupportedRichLink
    case unsupportedScan
    case unsupportedRecording
    case unsupportedDrawing
    case unsupportedAttachment
    case contentMismatch
}

enum SnapshotRestoreAction: Equatable, Sendable {
    case keep
    case unmark
    case recreateFile(SnapshotAttachmentMaterial)
    case recreateScan(SnapshotScanRecreation)
    case recreateRecording(SnapshotRecordingRecreation)
    case recreatedByParent(String)
    case recreateTable
    case recreateRichLink
    case recreateMap
    case recreatePaperDocument(SnapshotAttachmentMaterial, subtype: String)
    case recreateDrawing(SnapshotAttachmentMaterial?)
    case recreateInline(SnapshotInlineRecreation)
    case refuse(SnapshotRestoreRefusalReason)
}

struct SnapshotScanPageRecreation: Equatable, Sendable {
    var id: String
    var material: SnapshotAttachmentMaterial
    var filter: Int
    var orientation: Int
    var crop: ScanCrop?
    var hasEmbeddedMarkup: Bool
    var markupSHA256: String?
    var markupByteCount: Int?

    init(id: String, material: SnapshotAttachmentMaterial, filter: Int, orientation: Int,
         crop: ScanCrop?, hasEmbeddedMarkup: Bool = false,
         markupSHA256: String? = nil, markupByteCount: Int? = nil) {
        self.id = id; self.material = material; self.filter = filter; self.orientation = orientation
        self.crop = crop; self.hasEmbeddedMarkup = hasEmbeddedMarkup
        self.markupSHA256 = markupSHA256; self.markupByteCount = markupByteCount
    }
}

struct SnapshotScanRecreation: Equatable, Sendable {
    var parentID: String
    var pages: [SnapshotScanPageRecreation]
}

struct SnapshotRecordingFragmentRecreation: Equatable, Sendable {
    var id: String
    var material: SnapshotAttachmentMaterial
    var duration: Double
    var createdDate: Date?
    var transcriptVersion: Int?
    var transcript: [TranscriptWord]
}

struct SnapshotRecordingRecreation: Equatable, Sendable {
    var parentID: String
    var fragments: [SnapshotRecordingFragmentRecreation]
    var duration: Double
    var metadata: RecordingMetadata?

    var childID: String { fragments[0].id }
    var material: SnapshotAttachmentMaterial { fragments[0].material }
    var transcript: [TranscriptWord] { fragments.flatMap(\.transcript) }

    init(parentID: String, childID: String, material: SnapshotAttachmentMaterial,
         duration: Double, transcript: [TranscriptWord], metadata: RecordingMetadata? = nil) {
        self.parentID = parentID
        self.fragments = [SnapshotRecordingFragmentRecreation(
            id: childID, material: material, duration: duration,
            createdDate: nil, transcriptVersion: nil, transcript: transcript
        )]
        self.duration = duration; self.metadata = metadata
    }

    init(parentID: String, fragments: [SnapshotRecordingFragmentRecreation], duration: Double,
         metadata: RecordingMetadata? = nil) {
        self.parentID = parentID; self.fragments = fragments
        self.duration = duration; self.metadata = metadata
    }
}

enum SnapshotInlineRecreation: Equatable, Sendable {
    case hashtag(String)
    case noteLink(targetID: String, paragraphID: String?, paragraphName: String?, text: String)
    case divider
    case math(String)
    case mention(text: String, userRecordName: String)
}

struct SnapshotRestorePlannedAttachment: Equatable, Sendable {
    var id: String
    var typeUTI: String
    var action: SnapshotRestoreAction
}

struct SnapshotRestorePlan: Equatable, Sendable {
    var attachments: [SnapshotRestorePlannedAttachment]
    var canRestore: Bool { attachments.allSatisfy { if case .refuse = $0.action { false } else { true } } }

    func attachment(_ id: String) -> SnapshotRestorePlannedAttachment? {
        attachments.first { $0.id == id }
    }
}

enum SnapshotRestorePlanner {
    static func plan(
        snapshot: Note,
        verifiedArchive: SnapshotAttachmentArchive?,
        existing: [SnapshotRestoreExistingAttachment]
    ) -> SnapshotRestorePlan {
        let index = SnapshotIndex(snapshot: snapshot, archive: verifiedArchive, existing: existing)
        let planned = index.orderedIDs.map { id -> SnapshotRestorePlannedAttachment in
            let typeUTI = index.types[id]?.first ?? ""
            return SnapshotRestorePlannedAttachment(
                id: id,
                typeUTI: typeUTI,
                action: decision(id: id, typeUTI: typeUTI, index: index, archive: verifiedArchive)
            )
        }
        return SnapshotRestorePlan(attachments: planned)
    }

    private static func decision(
        id: String,
        typeUTI: String,
        index: SnapshotIndex,
        archive: SnapshotAttachmentArchive?
    ) -> SnapshotRestoreAction {
        if index.collisions.contains(id) { return .refuse(.idCollision) }
        if index.types[id]?.count != 1 { return .refuse(.typeMismatch) }

        if let recordingID = recordingRootID(for: id, index: index),
           let recording = index.attachments[recordingID],
           let childIDs = recording.childAttachmentIDs, !childIDs.isEmpty {
            let graphIDs = [recordingID] + childIDs
            let existingCount = graphIDs.reduce(0) { $0 + (index.existing[$1]?.count ?? 0) }
            if existingCount != 0 && existingCount != graphIDs.count {
                return .refuse(.parentChildTopology)
            }
            if existingCount == 0 {
                guard let recreation = recordingRecreation(recordingID, index: index, archive: archive) else {
                    return .refuse(.unsupportedRecording)
                }
                return id == recordingID ? .recreateRecording(recreation) : .recreatedByParent(recordingID)
            }
        }

        if let scanID = scanRootID(for: id, index: index),
           let scan = index.attachments[scanID],
           let pageIDs = scan.childAttachmentIDs, !pageIDs.isEmpty {
            let graphIDs = [scanID] + pageIDs
            let existingCount = graphIDs.reduce(0) { $0 + (index.existing[$1]?.count ?? 0) }
            if existingCount != 0 && existingCount != graphIDs.count {
                return .refuse(.parentChildTopology)
            }
            if existingCount == 0 {
                guard let recreation = scanRecreation(scanID, index: index, archive: archive) else {
                    return .refuse(.unsupportedScan)
                }
                return id == scanID ? .recreateScan(recreation) : .recreatedByParent(scanID)
            }
        }

        let rows = index.existing[id] ?? []
        if rows.count > 1 { return .refuse(.idCollision) }
        if let row = rows.first {
            guard row.belongsToTargetNote else { return .refuse(.idCollision) }
            guard row.typeUTI == typeUTI else { return .refuse(.typeMismatch) }
            guard (index.parentIDs[id]?.count ?? 0) <= 1 else { return .refuse(.parentChildTopology) }
            if index.legacyNestedMarkerIDs.contains(id) {
                guard row.parentID == nil || row.parentID.map({ index.cellTableIDs[id]?.contains($0) == true }) == true else {
                    return .refuse(.parentChildTopology)
                }
            } else {
                guard row.parentID == index.parentIDs[id]?.first else { return .refuse(.parentChildTopology) }
            }
            if let refusal = existingEvidenceRefusal(id: id, row: row, index: index, archive: archive) {
                return .refuse(refusal)
            }
            return row.isMarkedForDeletion ? .unmark : .keep
        }

        guard let attachment = index.attachments[id], index.attachmentCounts[id] == 1 else {
            return .refuse(.invalidSnapshot)
        }
        if index.archiveCollisions.contains(id) { return .refuse(.idCollision) }
        let parentedTableID = parentedInlineTableID(for: id, index: index)
        if index.topologyIDs.contains(id), parentedTableID == nil,
           !(attachment.kind == "table" && canRecreateMissingTableGraph(id, index: index)) {
            return .refuse(.parentChildTopology)
        }
        if attachment.kind == "table" {
            guard index.recreatableTableIDs.contains(id) else { return .refuse(.unsupportedTable) }
            if index.tableIDsWithNestedMarkers.contains(id) {
                guard canRecreateMissingTableGraph(id, index: index) else {
                    return .refuse(.parentChildTopology)
                }
            }
            guard index.topLevelMarkerCounts[id] == 1 else { return .refuse(.invalidSnapshot) }
            return .recreateTable
        }
        if attachment.hasMapLocation == true, attachment.typeUTI == "public.url" {
            guard let value = attachment.url, let url = URL(string: value),
                  (try? NativeMapURL.validate(url)) != nil else {
                return .refuse(.unsupportedRichLink)
            }
            guard index.topLevelMarkerCounts[id] == 1 else { return .refuse(.invalidSnapshot) }
            return .recreateMap
        }
        if attachment.url != nil || attachment.synapseDataBytes != nil || attachment.linkPreviewMetadataBytes != nil {
            guard let value = attachment.url, let url = URL(string: value),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  url.host?.isEmpty == false, url.user == nil, url.password == nil else {
                return .refuse(.unsupportedRichLink)
            }
            guard index.topLevelMarkerCounts[id] == 1 else { return .refuse(.invalidSnapshot) }
            return .recreateRichLink
        }
        if typeUTI == "com.apple.paper.doc.pdf" || typeUTI == "com.apple.paper.doc.scan" {
            guard index.topLevelMarkerCounts[id] == 1 else { return .refuse(.invalidSnapshot) }
            guard archive?.formatVersion == 1 else { return .refuse(.missingMaterial) }
            let materials = index.materials[id] ?? []
            guard materials.count == 1, let material = materials.first else {
                return .refuse(materials.count > 1 ? .idCollision : .missingMaterial)
            }
            guard material.typeUTI == typeUTI else { return .refuse(.typeMismatch) }
            guard material.parentID == nil else { return .refuse(.parentChildTopology) }
            let hasFallback = material.unavailableReason == nil && material.blobSHA256.map { hash in
                hash.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil
            } == true && (material.byteCount ?? 0) > 0
            let hasPaperBundle = material.paperBundleSHA256.map { hash in
                hash.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil
            } == true && (material.paperBundleByteCount ?? 0) > 0
            guard hasFallback || hasPaperBundle else {
                return .refuse(.missingBlob)
            }
            return .recreatePaperDocument(material, subtype: typeUTI.hasSuffix(".scan") ? "scan" : "pdf")
        }
        if attachment.kind == "drawing" {
            let payloads = index.materials[id] ?? []
            let lowerType = typeUTI.lowercased()
            if payloads.count == 1, let payload = payloads.first,
               ((payload.payloadKind == "paper-strokes-v1" ||
                    payload.payloadKind == "paper-canvases-v1" && payload.paperBundleArchived) && lowerType.contains("paper") ||
                payload.payloadKind == "legacy-drawing-v1" &&
                    (lowerType.contains("sketch") || lowerType.contains("drawing") && !lowerType.contains("paper"))),
               payload.typeUTI == typeUTI,
               payload.parentID == nil,
               payload.unavailableReason == nil,
               let hash = payload.blobSHA256,
               hash.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil,
               let byteCount = payload.byteCount, byteCount > 0 {
                guard index.topLevelMarkerCounts[id] == 1 else { return .refuse(.invalidSnapshot) }
                return .recreateDrawing(payload)
            }
            guard attachment.drawingSVG?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                return .refuse(.unsupportedDrawing)
            }
            guard index.topLevelMarkerCounts[id] == 1 else { return .refuse(.invalidSnapshot) }
            return .recreateDrawing(nil)
        }
        if let inline = inlineRecreation(attachment, snapshot: index.snapshot) {
            if index.nestedMarkerIDs.contains(id) {
                guard index.nestedMarkerCounts[id] == 1,
                      index.topLevelMarkerCounts[id, default: 0] == 0,
                      let tableIDs = index.cellTableIDs[id], tableIDs.count == 1,
                      let tableID = tableIDs.first,
                      index.nestedNilParentIDs.contains(id) || parentedTableID == tableID,
                      tableIsAvailableOrRecreatable(tableID, index: index) else {
                    return .refuse(.nestedAttachment)
                }
            } else {
                guard index.topLevelMarkerCounts[id] == 1 else { return .refuse(.invalidSnapshot) }
            }
            return .recreateInline(inline)
        }
        if index.nestedMarkerIDs.contains(id) { return .refuse(.nestedAttachment) }
        switch refusalForUnsupportedRecreation(attachment) {
        case .some(let reason): return .refuse(reason)
        case .none: break
        }
        guard index.topLevelMarkerCounts[id] == 1 else { return .refuse(.invalidSnapshot) }
        guard let archive, archive.formatVersion == 1 else { return .refuse(.missingMaterial) }
        let materials = index.materials[id] ?? []
        guard materials.count == 1, let material = materials.first else {
            return .refuse(materials.count > 1 ? .idCollision : .missingMaterial)
        }
        guard material.typeUTI == typeUTI else { return .refuse(.typeMismatch) }
        guard material.parentID == nil else { return .refuse(.parentChildTopology) }
        guard material.unavailableReason == nil else { return .refuse(.missingBlob) }
        guard let hash = material.blobSHA256,
              hash.count == 64,
              hash == hash.lowercased(),
              hash.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789abcdef").contains($0) }),
              let byteCount = material.byteCount,
              byteCount > 0 else { return .refuse(.missingBlob) }
        guard SnapshotRestoreFilename.forExplicitType(material) != nil else {
            return .refuse(.unsupportedAttachment)
        }
        return .recreateFile(material)
    }

    /// Rejects keeping a row whose collected evidence proves it differs from the snapshot.
    /// Evidence that was not collected is left to post-restore verification.
    private static func existingEvidenceRefusal(
        id: String,
        row: SnapshotRestoreExistingAttachment,
        index: SnapshotIndex,
        archive: SnapshotAttachmentArchive?
    ) -> SnapshotRestoreRefusalReason? {
        let evidence = row.evidence
        if let actualOrder = evidence.orderedChildIDs,
           let attachment = index.attachments[id],
           attachment.kind == "scan" || attachment.kind == "audio",
           let expectedOrder = attachment.childAttachmentIDs, !expectedOrder.isEmpty,
           actualOrder != expectedOrder {
            return .parentChildTopology
        }
        guard archive?.formatVersion == 1,
              let materials = index.materials[id], materials.count == 1,
              let material = materials.first,
              material.unavailableReason == nil else { return nil }
        func digest(_ sha256: String?, _ byteCount: Int?) -> SnapshotRestoreDigest? {
            guard let sha256, let byteCount else { return nil }
            return SnapshotRestoreDigest(sha256: sha256, byteCount: byteCount)
        }
        func differs(_ expected: SnapshotRestoreDigest?, _ actual: SnapshotRestoreDigestEvidence) -> Bool {
            switch actual {
            case .notCollected: return false
            case .absent: return expected != nil
            case .present(let value): return expected != value
            }
        }
        let pairs: [(SnapshotRestoreDigest?, SnapshotRestoreDigestEvidence)] = [
            (digest(material.blobSHA256, material.byteCount), evidence.blob),
            (digest(material.paperBundleSHA256, material.paperBundleByteCount), evidence.paperBundle),
            (digest(material.synapseSHA256, material.synapseByteCount), evidence.synapse),
            (digest(material.linkMetadataSHA256, material.linkMetadataByteCount), evidence.linkMetadata),
            (digest(material.scanMarkupSHA256, material.scanMarkupByteCount), evidence.scanMarkup),
        ]
        return pairs.contains(where: { differs($0.0, $0.1) }) ? .contentMismatch : nil
    }

    private static func parentedInlineTableID(for id: String, index: SnapshotIndex) -> String? {
        guard index.nestedMarkerIDs.contains(id),
              index.nestedMarkerCounts[id] == 1,
              index.topLevelMarkerCounts[id, default: 0] == 0,
              let tableIDs = index.cellTableIDs[id], tableIDs.count == 1,
              let tableID = tableIDs.first,
              index.parentIDs[id] == [tableID],
              index.graphParentIDs[id] == [tableID],
              index.attachments[tableID]?.typeUTI == "com.apple.notes.table",
              tableIsAvailableOrRecreatable(tableID, index: index) else { return nil }
        return tableID
    }

    private static func tableIsAvailableOrRecreatable(_ tableID: String, index: SnapshotIndex) -> Bool {
        if index.existing[tableID]?.count == 1,
           index.existing[tableID]?.first?.typeUTI == "com.apple.notes.table",
           index.existing[tableID]?.first?.belongsToTargetNote == true {
            return true
        }
        return canRecreateMissingTableGraph(tableID, index: index)
    }

    private static func canRecreateMissingTableGraph(_ tableID: String, index: SnapshotIndex) -> Bool {
        guard index.existing[tableID]?.isEmpty != false,
              index.attachments[tableID]?.kind == "table",
              index.attachmentCounts[tableID] == 1,
              index.recreatableTableIDs.contains(tableID),
              index.topLevelMarkerCounts[tableID] == 1 else { return false }
        let nestedIDs = Set(index.cellTableIDs.compactMap { id, tableIDs in
            tableIDs == [tableID] ? id : nil
        })
        guard !nestedIDs.isEmpty else { return true }
        let table = index.attachments[tableID]!
        let graphChildren = Set(table.childAttachmentIDs ?? []).union(table.childAttachments?.map(\.id) ?? [])
        guard graphChildren.isSubset(of: nestedIDs) else { return false }
        return nestedIDs.allSatisfy { id in
            guard index.collisions.contains(id) == false,
                  index.existing[id]?.isEmpty != false,
                  index.attachmentCounts[id] == 1,
                  index.types[id]?.count == 1,
                  index.nestedMarkerCounts[id] == 1,
                  index.topLevelMarkerCounts[id, default: 0] == 0,
                  index.legacyNestedMarkerIDs.contains(id) == false,
                  let attachment = index.attachments[id],
                  inlineRecreation(attachment, snapshot: index.snapshot) != nil else { return false }
            if index.nestedNilParentIDs.contains(id) {
                return index.parentIDs[id]?.isEmpty != false && index.graphParentIDs[id]?.isEmpty != false
            }
            return index.parentIDs[id] == [tableID] && index.graphParentIDs[id] == [tableID]
        }
    }

    private static func scanRootID(for id: String, index: SnapshotIndex) -> String? {
        if index.attachments[id]?.kind == "scan" { return id }
        guard let parentID = index.parentIDs[id]?.first,
              index.attachments[parentID]?.kind == "scan" else { return nil }
        return parentID
    }

    private static func recordingRootID(for id: String, index: SnapshotIndex) -> String? {
        if let attachment = index.attachments[id],
           attachment.kind == "audio", attachment.childAttachmentIDs?.isEmpty == false {
            return id
        }
        guard let parentID = index.parentIDs[id]?.first,
              let parent = index.attachments[parentID],
              parent.kind == "audio", parent.childAttachmentIDs?.isEmpty == false else { return nil }
        return parentID
    }

    private static func recordingRecreation(
        _ parentID: String,
        index: SnapshotIndex,
        archive: SnapshotAttachmentArchive?
    ) -> SnapshotRecordingRecreation? {
        guard archive?.formatVersion == 1,
              let parent = index.attachments[parentID],
              parent.kind == "audio",
              index.attachmentCounts[parentID] == 1,
              index.topLevelMarkerCounts[parentID] == 1,
              index.parentIDs[parentID]?.isEmpty != false,
              let childIDs = parent.childAttachmentIDs, (1...100).contains(childIDs.count),
              Set(childIDs).count == childIDs.count,
              let children = parent.childAttachments, children.count == childIDs.count,
              let duration = parent.duration, duration.isFinite, duration > 0,
              duration <= TranscriptLimits.maxSeconds,
              let transcript = Optional(parent.transcriptWords ?? []),
              TranscriptLimits.problem(in: transcript) == nil,
              let transcriptGroups = try? RecordingFragments.grouped(transcript, fragmentCount: childIDs.count),
              safeRecordingMetadata(parent.recording) else { return nil }
        let childrenByID = Dictionary(grouping: children, by: \.id)
        guard childrenByID.values.allSatisfy({ $0.count == 1 }) else { return nil }
        let fragmentMetadataRows = parent.recordingFragments ?? []
        let fragmentMetadataGroups = Dictionary(grouping: fragmentMetadataRows, by: \.id)
        guard fragmentMetadataGroups.values.allSatisfy({ $0.count == 1 }) else { return nil }
        let fragmentMetadata = fragmentMetadataGroups.mapValues { $0[0] }
        if !fragmentMetadata.isEmpty {
            guard fragmentMetadata.count == childIDs.count,
                  Set(fragmentMetadata.keys) == Set(childIDs),
                  fragmentMetadata.values.allSatisfy({ $0.createdDate != nil && $0.transcriptVersion != nil }),
                  Set(fragmentMetadata.values.compactMap(\.createdDate)).count == childIDs.count else { return nil }
            let dateOrder = fragmentMetadata.values.sorted { $0.createdDate! < $1.createdDate! }.map(\.id)
            guard dateOrder == childIDs else { return nil }
        } else if childIDs.count > 1 {
            return nil
        }
        var fragments: [SnapshotRecordingFragmentRecreation] = []
        for (offset, childID) in childIDs.enumerated() {
            guard let child = childrenByID[childID]?.first,
                  child.kind == "audio",
                  child.childAttachmentIDs?.isEmpty != false,
                  child.childAttachments?.isEmpty != false,
                  index.attachmentCounts[childID] == 1,
                  index.topLevelMarkerCounts[childID, default: 0] == 0,
                  index.parentIDs[childID] == [parentID] else { return nil }
            let childDuration = child.duration ?? (childIDs.count == 1 ? duration : 0)
            guard childDuration.isFinite, childDuration >= 0, childDuration <= TranscriptLimits.maxSeconds,
                  let materials = index.materials[childID], materials.count == 1,
                  let material = materials.first,
                  material.parentID == parentID,
                  material.typeUTI == child.typeUTI,
                  material.unavailableReason == nil,
                  material.payloadKind == nil,
                  let hash = material.blobSHA256,
                  hash.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil,
                  let byteCount = material.byteCount, byteCount > 0,
                  SnapshotRestoreFilename.derive(for: material) != nil else { return nil }
            let metadata = fragmentMetadata[childID]
            if let version = metadata?.transcriptVersion, !(0...1_000_000).contains(version) { return nil }
            fragments.append(SnapshotRecordingFragmentRecreation(
                id: childID, material: material, duration: childDuration,
                createdDate: metadata?.createdDate, transcriptVersion: metadata?.transcriptVersion,
                transcript: transcriptGroups[offset]
            ))
        }
        if fragments.count > 1 {
            let mediaDurations = fragments.map { fragment in
                fragment.material.mediaDuration ?? (fragment.duration > 0 ? fragment.duration : nil)
            }
            guard mediaDurations.allSatisfy({ $0 != nil }) else { return nil }
            let total = mediaDurations.compactMap { $0 }.reduce(0, +)
            guard abs(total - duration) <= max(0.25, duration * 0.05) else { return nil }
        }
        return SnapshotRecordingRecreation(parentID: parentID, fragments: fragments, duration: duration,
                                             metadata: normalizedRecordingMetadata(parent.recording))
    }

    private static func normalizedRecordingMetadata(_ metadata: RecordingMetadata?) -> RecordingMetadata? {
        guard var metadata else { return nil }
        if metadata.summary?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
            metadata.summary = nil
        }
        if metadata.topLineSummary?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
            metadata.topLineSummary = nil
        }
        let meaningful = metadata.summary != nil || metadata.topLineSummary != nil || metadata.summaryVersion != nil ||
            metadata.externalModelAttributionProviderName != nil || metadata.externalModelAttributionSymbolName != nil ||
            metadata.localSpeakerHandle != nil || metadata.remoteSpeakerHandle != nil || metadata.callType != nil ||
            metadata.isCallRecording == true || metadata.startTime != nil
        return meaningful ? metadata : nil
    }

    private static func safeRecordingMetadata(_ metadata: RecordingMetadata?) -> Bool {
        guard let metadata else { return true }
        let summaries = [metadata.summary, metadata.topLineSummary].compactMap { $0 }
        let hasSummary = summaries.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard summaries.allSatisfy({ $0.utf16.count <= 100_000 }),
              !hasSummary || metadata.summaryVersion.map({ (0...1_000_000).contains($0) }) == true,
              metadata.externalModelAttributionProviderName?.utf16.count ?? 0 <= 1_000,
              metadata.externalModelAttributionSymbolName?.utf16.count ?? 0 <= 1_000,
              metadata.localSpeakerHandle?.utf16.count ?? 0 <= 1_000,
              metadata.remoteSpeakerHandle?.utf16.count ?? 0 <= 1_000,
              metadata.callType.map({ (0...64).contains($0) }) ?? true else { return false }
        let hasCallFields = metadata.localSpeakerHandle != nil || metadata.remoteSpeakerHandle != nil ||
            metadata.callType != nil || metadata.startTime != nil
        return !hasCallFields || metadata.isCallRecording == true
    }

    private static func scanRecreation(
        _ parentID: String,
        index: SnapshotIndex,
        archive: SnapshotAttachmentArchive?
    ) -> SnapshotScanRecreation? {
        guard archive?.formatVersion == 1,
              let parent = index.attachments[parentID],
              parent.typeUTI == "com.apple.notes.gallery",
              index.attachmentCounts[parentID] == 1,
              index.topLevelMarkerCounts[parentID] == 1,
              index.parentIDs[parentID]?.isEmpty != false,
              let childIDs = parent.childAttachmentIDs,
              (1...100).contains(childIDs.count),
              Set(childIDs).count == childIDs.count,
              let children = parent.childAttachments,
              Dictionary(grouping: children, by: \.id).values.allSatisfy({ $0.count == 1 }),
              Set(children.map(\.id)) == Set(childIDs) else { return nil }
        let byID = Dictionary(uniqueKeysWithValues: children.map { ($0.id, $0) })
        var pages: [SnapshotScanPageRecreation] = []
        for childID in childIDs {
            guard let child = byID[childID],
                  child.childAttachmentIDs?.isEmpty != false,
                  child.childAttachments?.isEmpty != false,
                  index.attachmentCounts[childID] == 1,
                  index.topLevelMarkerCounts[childID, default: 0] == 0,
                  index.parentIDs[childID] == [parentID],
                  UTType(child.typeUTI)?.conforms(to: .image) == true,
                  let materials = index.materials[childID], materials.count == 1,
                  let material = materials.first,
                  material.parentID == parentID,
                  material.typeUTI == child.typeUTI,
                  material.unavailableReason == nil,
                  material.payloadKind == nil,
                  let hash = material.blobSHA256,
                  hash.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil,
                  let byteCount = material.byteCount, byteCount > 0,
                  SnapshotRestoreFilename.derive(for: material) != nil else { return nil }
            if child.scanHasMarkup == true {
                guard let markupHash = material.scanMarkupSHA256,
                      markupHash.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil,
                      let markupBytes = material.scanMarkupByteCount, markupBytes > 0 else { return nil }
            } else if material.scanMarkupSHA256 != nil || material.scanMarkupByteCount != nil {
                return nil
            }
            if child.scanHasEmbeddedMarkup == true, child.scanHasMarkup != true { return nil }
            let filter = child.scanFilter ?? 0
            let orientation = child.scanOrientation ?? 0
            guard (0...4).contains(filter), (0...3).contains(orientation),
                  validScanCrop(child.scanCrop) else { return nil }
            pages.append(SnapshotScanPageRecreation(
                id: childID, material: material, filter: filter,
                orientation: orientation, crop: child.scanCrop,
                hasEmbeddedMarkup: child.scanHasEmbeddedMarkup == true,
                markupSHA256: material.scanMarkupSHA256,
                markupByteCount: material.scanMarkupByteCount
            ))
        }
        return SnapshotScanRecreation(parentID: parentID, pages: pages)
    }

    private static func validScanCrop(_ crop: ScanCrop?) -> Bool {
        guard let crop else { return true }
        return [crop.bottomLeft, crop.bottomRight, crop.topLeft, crop.topRight]
            .allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.x >= 0 && $0.y >= 0 }
    }

    private static func inlineRecreation(_ attachment: Attachment, snapshot: Note) -> SnapshotInlineRecreation? {
        switch attachment.kind {
        case "hashtag":
            let value = (attachment.displayText ?? attachment.title ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let name = value.hasPrefix("#") ? String(value.dropFirst()) : value
            guard !name.isEmpty, !name.contains(where: { $0.isWhitespace || $0 == "#" }) else { return nil }
            return .hashtag(name)
        case "note-link":
            let savedTarget = AppleNotesLinkTarget.parse(attachment.targetNoteID)
            let referenceTarget = AppleNotesLinkTarget.parse(inlineReferenceURL(attachment.id, snapshot: snapshot))
            guard let target = savedTarget?.identifier.trimmingCharacters(in: .whitespacesAndNewlines),
                  !target.isEmpty else { return nil }
            let paragraphID = attachment.targetParagraphID ?? savedTarget?.paragraphID ?? referenceTarget?.paragraphID
            let text = (attachment.displayText ?? attachment.title ?? target)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .noteLink(targetID: target, paragraphID: paragraphID,
                             paragraphName: attachment.targetParagraphName,
                             text: text.isEmpty ? target : text)
        case "divider":
            return attachment.isDivider == true ? .divider : nil
        case "math":
            guard let expression = (attachment.mathExpression ?? attachment.graphExpression)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !expression.isEmpty else { return nil }
            return .math(expression)
        case "mention":
            guard snapshot.summary.isShared == true,
                  let identity = (attachment.participantUserID ?? attachment.participantID)?
                    .trimmingCharacters(in: .whitespacesAndNewlines), !identity.isEmpty else { return nil }
            let text = (attachment.participantName ?? attachment.displayText ?? identity)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .mention(text: text.isEmpty ? identity : text, userRecordName: identity)
        default:
            return nil
        }
    }

    private static func inlineReferenceURL(_ id: String, snapshot: Note) -> String? {
        if let value = snapshot.document?.runs.compactMap(\.attachment)
            .first(where: { $0.id == id })?.url { return value }
        if let tables = snapshot.document?.tableCells {
            for rows in tables.values {
                for row in rows {
                    for cell in row {
                        if let value = cell.runs.compactMap(\.attachment)
                            .first(where: { $0.id == id })?.url { return value }
                    }
                }
            }
        }
        return nil
    }

    private static func refusalForUnsupportedRecreation(_ attachment: Attachment) -> SnapshotRestoreRefusalReason? {
        if attachment.url != nil || attachment.synapseDataBytes != nil || attachment.linkPreviewMetadataBytes != nil {
            return .unsupportedRichLink
        }
        if attachment.recording != nil { return .unsupportedRecording }
        switch attachment.kind {
        case "pdf", "image": return nil
        case "file":
            return attachment.typeUTI.lowercased().hasPrefix("com.apple.notes.") ? .unsupportedAttachment : nil
        case "table": return .unsupportedTable
        case "scan": return .unsupportedScan
        case "audio": return .unsupportedRecording
        case "drawing": return .unsupportedDrawing
        case "link": return .unsupportedRichLink
        case "mention", "hashtag", "note-link", "math", "divider": return .unsupportedInline
        default: return .unsupportedAttachment
        }
    }
}

enum SnapshotRestoreFilename {
    private static func savedName(_ material: SnapshotAttachmentMaterial) -> String? {
        guard let filename = material.filename?.trimmingCharacters(in: .whitespacesAndNewlines),
              !filename.isEmpty else { return nil }
        let name = URL(fileURLWithPath: filename).lastPathComponent
        guard !name.isEmpty, name != ".", name != "..",
              name.lengthOfBytes(using: .utf8) <= 255,
              !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
        return name
    }

    static func requiresExplicitType(_ material: SnapshotAttachmentMaterial) -> Bool {
        if let name = savedName(material) {
            let ext = URL(fileURLWithPath: name).pathExtension
            guard !ext.isEmpty, let inferred = UTType(filenameExtension: ext) else { return true }
            return inferred.identifier.caseInsensitiveCompare(material.typeUTI) != .orderedSame
        }
        return UTType(material.typeUTI)?.preferredFilenameExtension == nil
    }

    static func forExplicitType(_ material: SnapshotAttachmentMaterial) -> String? {
        let type = material.typeUTI.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !type.isEmpty, type.utf16.count <= 1_024,
              !type.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
        if let name = savedName(material) { return name }
        return derive(for: material) ?? "attachment"
    }

    static func derive(for material: SnapshotAttachmentMaterial) -> String? {
        if let name = savedName(material) {
            let ext = URL(fileURLWithPath: name).pathExtension
            if !ext.isEmpty,
               let type = UTType(filenameExtension: ext),
               type.identifier.caseInsensitiveCompare(material.typeUTI) == .orderedSame {
                return name
            }
        }
        guard let ext = UTType(material.typeUTI)?.preferredFilenameExtension, !ext.isEmpty else { return nil }
        return "attachment.\(ext)"
    }
}

enum SnapshotAttachmentIDRemapper {
    static func remapDocument(_ original: NoteDocument, attachmentIDs mapping: [String: String]) -> NoteDocument {
        var document = original
        for index in document.runs.indices {
            if let oldID = document.runs[index].attachment?.id, let newID = mapping[oldID] {
                document.runs[index].attachment?.id = newID
            }
            if let oldParentID = document.runs[index].attachment?.parentAttachmentID,
               let newParentID = mapping[oldParentID] {
                document.runs[index].attachment?.parentAttachmentID = newParentID
            }
        }
        if let tables = document.tables {
            document.tables = Dictionary(uniqueKeysWithValues: tables.map { key, value in
                (mapping[key] ?? key, value)
            })
        }
        if let tableCells = document.tableCells {
            document.tableCells = Dictionary(uniqueKeysWithValues: tableCells.map { key, value in
                let rows = value.map { row in
                    row.map { cell -> TableCellDocument in
                        var cell = cell
                        for index in cell.runs.indices {
                            if let oldID = cell.runs[index].attachment?.id,
                               let newID = mapping[oldID] {
                                cell.runs[index].attachment?.id = newID
                            }
                            if let oldParentID = cell.runs[index].attachment?.parentAttachmentID,
                               let newParentID = mapping[oldParentID] {
                                cell.runs[index].attachment?.parentAttachmentID = newParentID
                            }
                        }
                        return cell
                    }
                }
                return (mapping[key] ?? key, rows)
            })
        }
        return document
    }

    static func remap(_ note: Note, attachmentIDs mapping: [String: String]) throws -> Note {
        guard !mapping.isEmpty else { return note }
        guard mapping.allSatisfy({ !$0.key.isEmpty && !$0.value.isEmpty }) else {
            throw NotesError("invalid_attachment_id_map", "Attachment IDs in a restore map cannot be empty.")
        }
        guard Set(mapping.values).count == mapping.values.count else {
            throw NotesError("attachment_id_collision", "More than one saved attachment maps to the same restored ID.")
        }

        var attachmentCounts: [String: Int] = [:]
        var allIDs: Set<String> = []
        var topologyIDs: Set<String> = []
        var parentByChild: [String: String] = [:]
        var childrenByParent: [String: Set<String>] = [:]
        var typeByID: [String: String] = [:]
        func collect(_ attachment: Attachment, parentID: String?) {
            attachmentCounts[attachment.id, default: 0] += 1
            allIDs.insert(attachment.id)
            typeByID[attachment.id] = attachment.typeUTI
            if let parentID {
                topologyIDs.insert(attachment.id)
                parentByChild[attachment.id] = parentID
                childrenByParent[parentID, default: []].insert(attachment.id)
            }
            if let children = attachment.childAttachmentIDs, !children.isEmpty {
                topologyIDs.insert(attachment.id)
                topologyIDs.formUnion(children)
                allIDs.formUnion(children)
                for child in children {
                    parentByChild[child] = attachment.id
                    childrenByParent[attachment.id, default: []].insert(child)
                }
            }
            for child in attachment.childAttachments ?? [] {
                topologyIDs.insert(attachment.id)
                collect(child, parentID: attachment.id)
            }
        }

        func component(containing start: String) -> Set<String> {
            var result: Set<String> = [], pending = [start]
            while let current = pending.popLast() {
                guard result.insert(current).inserted else { continue }
                if let parent = parentByChild[current] { pending.append(parent) }
                pending.append(contentsOf: childrenByParent[current] ?? [])
            }
            return result
        }
        for attachment in note.attachments { collect(attachment, parentID: nil) }

        var topLevelMarkerCounts: [String: Int] = [:]
        var nestedMarkerIDs: Set<String> = []
        var nestedMarkerCounts: [String: Int] = [:]
        var nestedTableIDs: [String: Set<String>] = [:]
        if let document = note.document {
            for reference in document.runs.compactMap(\.attachment) {
                topLevelMarkerCounts[reference.id, default: 0] += 1
                allIDs.insert(reference.id)
            }
            for key in document.tables?.keys ?? Dictionary<String, [[String]]>().keys { allIDs.insert(key) }
            for (tableID, rows) in document.tableCells ?? [:] {
                allIDs.insert(tableID)
                for row in rows {
                    for cell in row {
                        for reference in cell.runs.compactMap(\.attachment) {
                            nestedMarkerIDs.insert(reference.id)
                            nestedMarkerCounts[reference.id, default: 0] += 1
                            nestedTableIDs[reference.id, default: []].insert(tableID)
                            allIDs.insert(reference.id)
                        }
                    }
                }
            }
        }

        for (oldID, newID) in mapping {
            guard attachmentCounts[oldID] == 1 else {
                throw NotesError("attachment_id_not_found", "Attachment \(oldID) does not appear exactly once in the snapshot graph.")
            }
            let topLevelCount = topLevelMarkerCounts[oldID, default: 0]
            let nestedCount = nestedMarkerCounts[oldID, default: 0]
            let parentedTableCell = parentByChild[oldID].map { parentID in
                topLevelCount == 0 && nestedCount == 1 &&
                    nestedTableIDs[oldID] == [parentID] &&
                    typeByID[parentID] == "com.apple.notes.table"
            } ?? false
            let validMarkerPosition: Bool
            if parentByChild[oldID] == nil {
                validMarkerPosition = (topLevelCount == 1 && nestedCount == 0) ||
                    (topLevelCount == 0 && nestedCount == 1)
            } else {
                validMarkerPosition = (topLevelCount == 0 && nestedCount == 0) || parentedTableCell
            }
            guard validMarkerPosition else {
                throw NotesError("nested_attachment_remap_unsupported", "Attachment \(oldID) has an unsupported marker position in the snapshot.")
            }
            if topologyIDs.contains(oldID) {
                let graph = component(containing: oldID)
                guard parentedTableCell || graph.isSubset(of: Set(mapping.keys)) else {
                    throw NotesError("nested_attachment_remap_unsupported", "Every attachment in a parent-child graph must be remapped together.")
                }
            }
            if newID != oldID, allIDs.contains(newID) {
                throw NotesError("attachment_id_collision", "Restored attachment ID \(newID) already exists in the snapshot.")
            }
        }

        var result = note
        if let document = result.document {
            result.document = remapDocument(document, attachmentIDs: mapping)
        }
        func remapAttachment(_ attachment: Attachment) -> Attachment {
            var remapped = attachment
            remapped.id = mapping[attachment.id] ?? attachment.id
            remapped.childAttachmentIDs = attachment.childAttachmentIDs?.map { mapping[$0] ?? $0 }
            remapped.childAttachments = attachment.childAttachments?.map(remapAttachment)
            remapped.recordingFragments = attachment.recordingFragments?.map { fragment in
                var fragment = fragment
                fragment.id = mapping[fragment.id] ?? fragment.id
                return fragment
            }
            return remapped
        }
        result.attachments = result.attachments.map(remapAttachment)
        return result
    }
}

private struct SnapshotIndex {
    var snapshot: Note!
    var orderedIDs: [String] = []
    var orderedIDSet: Set<String> = []
    var types: [String: Set<String>] = [:]
    var attachments: [String: Attachment] = [:]
    var attachmentCounts: [String: Int] = [:]
    var topLevelMarkerCounts: [String: Int] = [:]
    var nestedMarkerIDs: Set<String> = []
    var nestedMarkerCounts: [String: Int] = [:]
    var nestedNilParentIDs: Set<String> = []
    var legacyNestedMarkerIDs: Set<String> = []
    var cellTableIDs: [String: Set<String>] = [:]
    var recreatableTableIDs: Set<String> = []
    var tableIDsWithNestedMarkers: Set<String> = []
    var topologyIDs: Set<String> = []
    var parentIDs: [String: Set<String>] = [:]
    var graphParentIDs: [String: Set<String>] = [:]
    var collisions: Set<String> = []
    var archiveCollisions: Set<String> = []
    var materials: [String: [SnapshotAttachmentMaterial]] = [:]
    var existing: [String: [SnapshotRestoreExistingAttachment]] = [:]

    private init() {}

    init(snapshot: Note, archive: SnapshotAttachmentArchive?, existing rows: [SnapshotRestoreExistingAttachment]) {
        self.init()
        self.snapshot = snapshot
        for attachment in snapshot.attachments { recordAttachment(attachment, parentID: nil) }

        if let document = snapshot.document {
            for reference in document.runs.compactMap(\.attachment) {
                recordType(reference.id, reference.typeUTI)
                topLevelMarkerCounts[reference.id, default: 0] += 1
            }
            for (tableID, rows) in document.tableCells ?? [:] {
                order(tableID)
                recreatableTableIDs.insert(tableID)
                for row in rows {
                    for cell in row {
                        for reference in cell.runs.compactMap(\.attachment) {
                            recordType(reference.id, reference.typeUTI)
                            nestedMarkerIDs.insert(reference.id)
                            nestedMarkerCounts[reference.id, default: 0] += 1
                            if nestedMarkerCounts[reference.id, default: 0] > 1 { collisions.insert(reference.id) }
                            tableIDsWithNestedMarkers.insert(tableID)
                            cellTableIDs[reference.id, default: []].insert(tableID)
                            if reference.parentAttachmentCaptured == true {
                                if let parentID = reference.parentAttachmentID {
                                    parentIDs[reference.id, default: []].insert(parentID)
                                } else {
                                    nestedNilParentIDs.insert(reference.id)
                                }
                            } else {
                                legacyNestedMarkerIDs.insert(reference.id)
                            }
                        }
                    }
                }
            }
            recreatableTableIDs.formUnion(document.tables?.keys ?? Dictionary<String, [[String]]>().keys)
        }

        for material in archive?.attachments ?? [] {
            materials[material.id, default: []].append(material)
            if materials[material.id, default: []].count > 1 { archiveCollisions.insert(material.id) }
            if material.parentID != nil { topologyIDs.insert(material.id) }
        }
        for (id, parents) in parentIDs where parents.count > 1 { collisions.insert(id) }
        for row in rows {
            existing[row.id, default: []].append(row)
            if existing[row.id, default: []].count > 1 || !row.belongsToTargetNote { collisions.insert(row.id) }
        }
    }

    private mutating func order(_ id: String) {
        if orderedIDSet.insert(id).inserted { orderedIDs.append(id) }
    }

    private mutating func recordType(_ id: String, _ type: String) {
        order(id)
        types[id, default: []].insert(type)
    }

    private mutating func recordAttachment(_ attachment: Attachment, parentID: String?) {
        recordType(attachment.id, attachment.typeUTI)
        attachmentCounts[attachment.id, default: 0] += 1
        if attachmentCounts[attachment.id, default: 0] > 1 { collisions.insert(attachment.id) }
        if attachments[attachment.id] == nil { attachments[attachment.id] = attachment }
        if parentID != nil {
            topologyIDs.insert(attachment.id)
            if let parentID {
                topologyIDs.insert(parentID)
                parentIDs[attachment.id, default: []].insert(parentID)
                graphParentIDs[attachment.id, default: []].insert(parentID)
            }
        }
        if let childIDs = attachment.childAttachmentIDs, !childIDs.isEmpty {
            topologyIDs.insert(attachment.id)
            for childID in childIDs {
                order(childID)
                topologyIDs.insert(childID)
                parentIDs[childID, default: []].insert(attachment.id)
                graphParentIDs[childID, default: []].insert(attachment.id)
            }
        }
        for child in attachment.childAttachments ?? [] {
            topologyIDs.insert(attachment.id)
            recordAttachment(child, parentID: attachment.id)
        }
    }
}
