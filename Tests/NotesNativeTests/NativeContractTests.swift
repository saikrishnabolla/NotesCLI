import XCTest
import NotesCore
@testable import NotesNative

private struct FakeNativeContractRuntime: NativeContractRuntime {
    var osBuild = "26B131"
    var macOS = "27.2.1"
    var classes: Set<String> = []
    var encodings: [String: String] = [:]
    var entities: [String: Set<String>] = [:]
    var columns: [String: Set<String>] = [:]
    var kvcKeys: Set<String> = []
    var ivars: Set<String> = []

    func classExists(_ name: String) -> Bool { classes.contains(name) }
    func methodEncoding(class name: String, selector: String, isClassMethod: Bool) -> String? {
        encodings["\(isClassMethod ? "+" : "-")[\(name) \(selector)]"]
    }
    func attributes(entity: String) -> Set<String>? { entities[entity] }
    func hasKVCKey(_ key: String) -> Bool { kvcKeys.contains(key) }
    func hasIvar(_ name: String) -> Bool { ivars.contains(name) }
    func columns(table: String) -> Set<String>? { columns[table] }
}

private final class StoreByteCounter: @unchecked Sendable {
    var bytesWritten = 0
}

final class NativeContractTests: XCTestCase {
    private func report(failing feature: NativeContractFeature) -> NativeContractReport {
        let features = NativeContractFeature.allCases.map { candidate in
            let failures: [NativeContractFailure] = candidate == feature
                ? [.init(kind: .selector, name: "fault_injected", expected: nil, actual: nil)] : []
            return NativeFeatureContractReport(feature: candidate, failures: failures, ok: failures.isEmpty)
        }
        return NativeContractReport(schemaVersion: 1, verifiedOSBuild: "26B131", osBuild: "26B131",
                                    macOS: "27.2.1", dyldSharedCacheUUID: "test", manifestHash: "test",
                                    cliVersion: "test", cacheKey: "test", checkedAt: Date(),
                                    classCount: 0, selectorCount: 0, kvcKeyCount: 0, ivarCount: 0,
                                    objcMessageCount: 0, abiEncodingCount: 0,
                                    features: features, ok: false)
    }

    func testChangedEncodingFailsOnlyOwningFeature() throws {
        let table = NativeContractRequirement.selector(
            feature: .tables,
            className: "ICTable",
            selector: "rowCount",
            isClassMethod: false,
            encoding: "Q16@0:8"
        )
        let core = NativeContractRequirement.selector(
            feature: .core,
            className: "ICNote",
            selector: "saveNoteData",
            isClassMethod: false,
            encoding: "B16@0:8"
        )
        let runtime = FakeNativeContractRuntime(
            classes: ["ICTable", "ICNote"],
            encodings: ["-[ICTable rowCount]": "I16@0:8", "-[ICNote saveNoteData]": "B16@0:8"]
        )

        let report = NativeContractProbe.evaluate(requirements: [table, core], runtime: runtime)

        XCTAssertTrue(report.feature(.core).ok)
        XCTAssertFalse(report.feature(.tables).ok)
        XCTAssertEqual(report.feature(.tables).failures.first?.kind, .methodEncoding)
        XCTAssertThrowsError(try report.require(.tables)) {
            let error = $0 as? NotesError
            XCTAssertEqual(error?.code, "native_contract_changed")
            XCTAssertTrue(error?.message.contains("-[ICTable rowCount]") == true)
            XCTAssertTrue(error?.hint?.contains("notescli doctor --native --json") == true)
        }
    }

    func testMissingSelectorAndColumnAreNamed() {
        let requirements: [NativeContractRequirement] = [
            .selector(feature: .scans, className: "ICDocCamScannedDocumentEditor",
                      selector: "setQuad:forAttachmentWithIdentifier:", isClassMethod: false,
                      encoding: "v32@0:8@16@24"),
            .column(feature: .scans, table: "ZICCLOUDSYNCINGOBJECT", name: "ZMARKUPMODELDATA"),
        ]
        let runtime = FakeNativeContractRuntime(
            classes: ["ICDocCamScannedDocumentEditor"],
            columns: ["ZICCLOUDSYNCINGOBJECT": []]
        )

        let failures = NativeContractProbe.evaluate(requirements: requirements, runtime: runtime)
            .feature(.scans).failures

        XCTAssertEqual(Set(failures.map(\.kind)), [.selector, .column])
        XCTAssertEqual(Set(failures.map(\.name)), [
            "-[ICDocCamScannedDocumentEditor setQuad:forAttachmentWithIdentifier:]",
            "ZICCLOUDSYNCINGOBJECT.ZMARKUPMODELDATA",
        ])
    }

    func testMissingEntityAttributeFailsClosed() {
        let requirement = NativeContractRequirement.attribute(
            feature: .recordings,
            entity: "ICAttachment",
            name: "duration"
        )
        let runtime = FakeNativeContractRuntime(entities: ["ICAttachment": ["identifier"]])

        let report = NativeContractProbe.evaluate(requirements: [requirement], runtime: runtime)

        XCTAssertFalse(report.ok)
        XCTAssertEqual(report.feature(.recordings).failures.first?.kind, .attribute)
    }

    func testMissingGeneratedSelectorKVCKeyAndIvarFailClosed() {
        let requirements: [NativeContractRequirement] = [
            .selector(feature: .paper, className: nil, selector: "paperSelector:",
                      isClassMethod: nil, encoding: nil),
            .kvc(feature: .paper, name: "paperBundleURL"),
            .ivar(feature: .paper, name: "_paperArchive"),
        ]

        let failures = NativeContractProbe.evaluate(
            requirements: requirements,
            runtime: FakeNativeContractRuntime()
        ).feature(.paper).failures

        XCTAssertEqual(Set(failures.map(\.kind)), [.selector, .kvc, .ivar])
        XCTAssertEqual(Set(failures.map(\.name)), ["paperSelector:", "paperBundleURL", "_paperArchive"])
    }

    func testCacheKeyIncludesDyldManifestAndCLIVersion() {
        let runtime = FakeNativeContractRuntime()
        func key(_ dyld: String, _ manifest: String, _ version: String) -> String {
            NativeContractProbe.evaluate(requirements: [], runtime: runtime, dyldUUID: dyld,
                                         cliVersion: version, manifestHash: manifest).cacheKey
        }
        let baseline = key("dyld-a", "manifest-a", "cli-a")
        XCTAssertNotEqual(baseline, key("dyld-b", "manifest-a", "cli-a"))
        XCTAssertNotEqual(baseline, key("dyld-a", "manifest-b", "cli-a"))
        XCTAssertNotEqual(baseline, key("dyld-a", "manifest-a", "cli-b"))
    }

    func testPerFeatureFaultInjectionWritesZeroStoreBytes() throws {
        for feature in NativeContractFeature.allCases {
            let counter = StoreByteCounter()
            let writer = NativeNotesWriter(
                operationID: { "fault" },
                contextProvider: {
                    counter.bytesWritten += 1
                    throw NotesError("test", "The store must not open.")
                },
                contractProvider: { self.report(failing: feature) }
            )
            let operation: () throws -> Void
            switch feature {
            case .core:
                operation = { _ = try writer.setPinned("note", pinned: true, allowShared: false) }
            case .tags:
                operation = { _ = try writer.addTag("note", tag: "canary", position: nil, allowShared: false) }
            case .tables:
                operation = { _ = try writer.createTable("note", rows: [["cell"]], position: nil, allowShared: false) }
            case .scans:
                operation = { _ = try writer.setScanMarkupData("note", attachmentID: "scan", pageID: "page",
                                                                 data: Data([1]), allowShared: false) }
            case .recordings:
                operation = { _ = try writer.writeRecordingTranscripts("note", transcripts: ["audio": []], allowShared: false) }
            case .paper:
                let frozen = try FrozenAttachmentInput(data: Data([1]), suggestedName: "paper.pdf")
                operation = { _ = try writer.insertPaperDocument("note", frozen: frozen, subtype: "pdf",
                                                                  position: nil, allowShared: false) }
            }
            XCTAssertThrowsError(try operation(), feature.rawValue) {
                XCTAssertEqual(($0 as? NotesError)?.code, "native_contract_changed", feature.rawValue)
            }
            XCTAssertEqual(counter.bytesWritten, 0, feature.rawValue)
        }
    }

    func testGeneratedManifestMatchesNativeSources() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let process = Process()
        process.currentDirectoryURL = root
        process.executableURL = root.appendingPathComponent("scripts/generate_native_contract.py")
        process.arguments = ["--check"]
        let output = Pipe(); process.standardOutput = output; process.standardError = output
        try process.run(); process.waitUntilExit()
        let message = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, message)
    }

    func testEveryABISensitiveMessageHasARecordedEncoding() {
        let sensitive = NativeContractManifest.generatedObjCMessages.filter {
            $0.signature.contains("CGRect") || $0.signature.contains("CGPoint") ||
                $0.signature.contains("NSRange") || $0.signature.contains("double")
        }

        XCTAssertEqual(sensitive.count, 26)
        for message in sensitive {
            XCTAssertFalse(message.selector.hasPrefix("<dynamic"), message.source)
            XCTAssertNotNil(NativeContractManifest.abiEncodings[message.selector],
                            "\(message.source): \(message.selector)")
        }
    }
}
