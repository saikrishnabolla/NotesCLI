// swift-tools-version:6.0
import PackageDescription
import Foundation

let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let executableInfoPlist = ProcessInfo.processInfo.environment["NOTESCLI_INFO_PLIST"]
    ?? packageRoot + "/Sources/notescli/Info.plist"

let package = Package(
    name: "NotesCLI",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "notescli", targets: ["notescli"]),
        .executable(name: "Notes CLI", targets: ["NotesCapabilityHost"]),
        .library(name: "NotesCore", targets: ["NotesCore"]),
        .library(name: "NotesSync", targets: ["NotesSync"]),
        .library(name: "NotesSafety", targets: ["NotesSafety"]),
        .library(name: "NotesDiagrams", targets: ["NotesDiagrams"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
        .package(url: "https://github.com/swiftlang/swift-markdown.git", from: "0.9.0"),
    ],
    targets: [
        // Pure Swift: model, protobuf decoding, renderers. No Apple frameworks, so it builds on Linux.
        .target(name: "NotesCore", dependencies: [
            .product(name: "Markdown", package: "swift-markdown"),
        ]),
        // macOS: read-only NoteStore.sqlite snapshot reader.
        .target(name: "NotesStore", dependencies: ["NotesCore"], linkerSettings: [
            .linkedLibrary("sqlite3"), .linkedFramework("PDFKit"), .linkedFramework("ImageIO"),
            .linkedFramework("AVFoundation"), .linkedFramework("AppKit"), .linkedFramework("PencilKit")
        ]),
        .target(name: "NotesIndex", dependencies: ["NotesCore"], linkerSettings: [.linkedLibrary("sqlite3")]),
        // macOS: writes through Notes.app scripting, verified by reading back.
        .target(name: "NotesAutomation", dependencies: ["NotesCore"]),
        // macOS: rich writes through NotesShared, loaded only at runtime.
        .target(name: "NotesNativeObjC", linkerSettings: [
            .linkedFramework("CoreData"), .linkedFramework("AppKit"), .linkedFramework("ImageIO")
        ]),
        .target(name: "NotesNative", dependencies: ["NotesCore", "NotesStore", "NotesNativeObjC", "NotesDiagrams"], linkerSettings: [
            .linkedFramework("AVFoundation"), .linkedFramework("Speech"), .linkedFramework("PencilKit"),
            .linkedFramework("Vision"), .linkedFramework("CoreImage"), .linkedFramework("ImageIO"),
            .linkedLibrary("sqlite3")
        ]),
        .target(name: "NotesDiagrams", dependencies: ["NotesCore"], linkerSettings: [
            .linkedFramework("AppKit"), .linkedFramework("CoreGraphics"), .linkedFramework("WebKit")
        ]),
        .target(name: "NotesHost", dependencies: ["NotesCore"]),
        .executableTarget(name: "NotesCapabilityHost", dependencies: ["NotesHost"], linkerSettings: [
            .linkedFramework("Security")
        ]),
        // MCP server over stdio, same operations as the CLI.
        // Write journal, snapshots/undo, and the write-folder allowlist.
        .target(name: "NotesSafety", dependencies: ["NotesCore"], linkerSettings: [
            .linkedFramework("AVFoundation"), .linkedLibrary("sqlite3")
        ]),
        .target(name: "NotesMCP", dependencies: ["NotesCore", "NotesIndex", "NotesNative", "NotesSafety", "NotesStore", "NotesSync"], linkerSettings: [
            .linkedFramework("ImageIO"), .linkedFramework("CoreGraphics"), .linkedFramework("Speech")
        ]),
        .target(name: "NotesSync", dependencies: ["NotesCore"], linkerSettings: [
            .linkedLibrary("sqlite3"),
            .linkedFramework("CoreServices"),
            .linkedFramework("AppKit"),
            .linkedFramework("PDFKit"),
        ]),
        .executableTarget(name: "notescli", dependencies: [
            "NotesCore", "NotesStore", "NotesIndex", "NotesAutomation", "NotesNative", "NotesMCP", "NotesSync", "NotesSafety", "NotesDiagrams", "NotesHost",
            .product(name: "ArgumentParser", package: "swift-argument-parser"),
        ], exclude: ["Info.plist"], linkerSettings: [.unsafeFlags([
            "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist",
            "-Xlinker", executableInfoPlist,
        ])]),
        .testTarget(name: "NotesCoreTests", dependencies: ["NotesCore"]),
        .testTarget(name: "NotesStoreTests", dependencies: ["NotesStore", "NotesCore"]),
        .testTarget(name: "NotesIndexTests", dependencies: ["NotesIndex", "NotesStore", "NotesCore"]),
        .testTarget(name: "NotesAutomationTests", dependencies: ["NotesAutomation", "NotesCore"]),
        .testTarget(name: "NotesNativeTests", dependencies: ["NotesNative", "NotesAutomation", "NotesCore", "NotesSafety", "NotesStore"]),
        .testTarget(name: "NotesSafetyTests", dependencies: ["NotesSafety", "NotesCore"]),
        .testTarget(name: "NotesMCPTests", dependencies: ["NotesMCP", "NotesCore", "NotesSafety"]),
        .testTarget(name: "NotesSyncTests", dependencies: ["NotesSync", "NotesCore"]),
        .testTarget(name: "NotesDiagramsTests", dependencies: ["NotesDiagrams", "NotesCore"]),
        .testTarget(name: "NotesHostTests", dependencies: ["NotesHost"]),
    ]
)
