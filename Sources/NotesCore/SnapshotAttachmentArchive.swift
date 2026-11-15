import Foundation

public struct SnapshotAttachmentMaterial: Codable, Sendable, Equatable {
    public var id: String
    public var typeUTI: String
    public var filename: String?
    public var title: String?
    public var parentID: String?
    public var blobSHA256: String?
    public var byteCount: Int?
    public var mediaDuration: Double?
    public var payloadKind: String?
    public var paperBundleSHA256: String?
    public var paperBundleByteCount: Int?
    public var synapseSHA256: String?
    public var synapseByteCount: Int?
    public var linkMetadataSHA256: String?
    public var linkMetadataByteCount: Int?
    public var scanMarkupSHA256: String?
    public var scanMarkupByteCount: Int?
    public var unavailableReason: String?

    public init(id: String, typeUTI: String, filename: String? = nil, title: String? = nil,
                parentID: String? = nil, blobSHA256: String? = nil, byteCount: Int? = nil,
                mediaDuration: Double? = nil,
                payloadKind: String? = nil, paperBundleSHA256: String? = nil,
                paperBundleByteCount: Int? = nil, synapseSHA256: String? = nil,
                synapseByteCount: Int? = nil, linkMetadataSHA256: String? = nil,
                linkMetadataByteCount: Int? = nil, scanMarkupSHA256: String? = nil,
                scanMarkupByteCount: Int? = nil, unavailableReason: String? = nil) {
        self.id = id
        self.typeUTI = typeUTI
        self.filename = filename
        self.title = title
        self.parentID = parentID
        self.blobSHA256 = blobSHA256
        self.byteCount = byteCount
        self.mediaDuration = mediaDuration
        self.payloadKind = payloadKind
        self.paperBundleSHA256 = paperBundleSHA256
        self.paperBundleByteCount = paperBundleByteCount
        self.synapseSHA256 = synapseSHA256
        self.synapseByteCount = synapseByteCount
        self.linkMetadataSHA256 = linkMetadataSHA256
        self.linkMetadataByteCount = linkMetadataByteCount
        self.scanMarkupSHA256 = scanMarkupSHA256
        self.scanMarkupByteCount = scanMarkupByteCount
        self.unavailableReason = unavailableReason
    }

    public var archived: Bool { blobSHA256 != nil && byteCount != nil }
    public var paperBundleArchived: Bool { paperBundleSHA256 != nil && paperBundleByteCount != nil }
}

public struct SnapshotLinkPayload: Sendable, Equatable {
    public var synapseData: Data?
    public var linkPresentationMetadata: Data?

    public init(synapseData: Data? = nil, linkPresentationMetadata: Data? = nil) {
        self.synapseData = synapseData
        self.linkPresentationMetadata = linkPresentationMetadata
    }
}

public struct SnapshotAttachmentArchive: Codable, Sendable, Equatable {
    public var formatVersion: Int
    public var attachments: [SnapshotAttachmentMaterial]

    public init(formatVersion: Int = 1, attachments: [SnapshotAttachmentMaterial]) {
        self.formatVersion = formatVersion
        self.attachments = attachments
    }
}

public protocol SnapshotBlobSource: Sendable {
    func verifiedData(sha256: String, byteCount: Int) throws -> Data
}

public struct SnapshotRestoreMaterial: Sendable {
    public let archive: SnapshotAttachmentArchive
    public let blobs: any SnapshotBlobSource

    public init(archive: SnapshotAttachmentArchive, blobs: any SnapshotBlobSource) {
        self.archive = archive
        self.blobs = blobs
    }
}
