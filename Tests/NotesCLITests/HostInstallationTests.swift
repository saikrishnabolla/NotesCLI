import Foundation
import NotesCore
import XCTest
@testable import notescli

final class HostInstallationTests: XCTestCase {
    func testLiteralBodySearchFlagsDoNotBypassTheHost() {
        let environment = ["NOTESCLI_CAPABILITY_HOST": "force"]
        for query in ["--help", "-h", "--version", "--backend=fake"] {
            XCTAssertTrue(NotesCLI.shouldUseCapabilityHost(arguments: ["editor-body-search", "--json", "--", query],
                                                           environment: environment))
        }
        XCTAssertFalse(NotesCLI.shouldUseCapabilityHost(arguments: ["editor-body-search", "--help"],
                                                        environment: environment))
    }

    func testCommandsAndReadinessUseTheSameCapabilityHostRoutingPolicy() {
        func skipCheck() -> Bool { XCTFail("This route must not probe the installed helper"); return false }
        XCTAssertFalse(CapabilityHostRouting.usesHost(backend: "default",
            environment: ["NOTESCLI_CAPABILITY_HOST": "direct"], needsUpgrade: skipCheck, isAvailable: skipCheck))
        XCTAssertTrue(CapabilityHostRouting.usesHost(backend: "default",
            environment: ["NOTESCLI_CAPABILITY_HOST": "force"], needsUpgrade: skipCheck, isAvailable: skipCheck))
        XCTAssertFalse(CapabilityHostRouting.usesHost(backend: "fake",
            environment: ["NOTESCLI_CAPABILITY_HOST": "force"], needsUpgrade: skipCheck, isAvailable: skipCheck))
        XCTAssertFalse(CapabilityHostRouting.usesHost(backend: "default",
            environment: ["NOTESCLI_HOST_ACTIVE": "1", "NOTESCLI_CAPABILITY_HOST": "force"],
            needsUpgrade: skipCheck, isAvailable: skipCheck))
        XCTAssertFalse(CapabilityHostRouting.usesHost(backend: "default",
            environment: [:], needsUpgrade: { true }, isAvailable: skipCheck))
        for available in [true, false] {
            XCTAssertEqual(CapabilityHostRouting.usesHost(backend: "default",
                environment: [:], needsUpgrade: { false }, isAvailable: { available }), available)
        }
    }

    func testOnboardingDoesNotKeepAnOlderHelperWithTheSameVersion() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) }
        let installed = root.appendingPathComponent("installed.app")
        let packaged = root.appendingPathComponent("packaged.app")
        let plist = try PropertyListSerialization.data(fromPropertyList: [
            "CFBundleShortVersionString": notesCLIVersion,
            "CFBundleVersion": notesCLIVersion,
        ], format: .xml, options: 0)
        for bundle in [installed, packaged] {
            let contents = bundle.appendingPathComponent("Contents")
            try fm.createDirectory(at: contents, withIntermediateDirectories: true)
            try plist.write(to: contents.appendingPathComponent("Info.plist"))
        }
        let oldHelper = installed.appendingPathComponent("Contents/Helpers/notescli")
        let newHelper = packaged.appendingPathComponent("Contents/Helpers/notescli")
        let oldCode = Data([1])
        let newCode = Data([2])
        func current(_ source: URL?, identities: [URL: Data]) -> Bool {
            HostInstallation.isCurrentInstall(at: installed, packagedSource: source,
                                              validate: { $0 == installed }, identity: { identities[$0] })
        }
        XCTAssertFalse(current(packaged, identities: [
            installed: oldCode, packaged: oldCode, oldHelper: oldCode, newHelper: newCode,
        ]))
        XCTAssertFalse(current(packaged, identities: [
            installed: oldCode, packaged: newCode, oldHelper: oldCode, newHelper: oldCode,
        ]))
        XCTAssertTrue(current(packaged, identities: [
            installed: newCode, packaged: newCode, oldHelper: newCode, newHelper: newCode,
        ]))
        XCTAssertFalse(current(packaged, identities: [installed: newCode, packaged: newCode]))
        XCTAssertTrue(current(installed, identities: [:]))
        XCTAssertTrue(current(nil, identities: [:]))
    }
}
