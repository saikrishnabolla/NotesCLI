// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "NotesCLI",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "notescli", targets: ["notescli"]),
        .library(name: "NotesCore", targets: ["NotesCore"]),
        .library(name: "NotesSync", targets: ["NotesSync"]),
        .library(name: "NotesSafety", targets: ["NotesSafety"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        // Pure Swift: model, protobuf decoding, renderers. No Apple frameworks, so it builds on Linux.
        .target(name: "NotesCore"),
        // macOS: read-only NoteStore.sqlite snapshot reader.
        .target(name: "NotesStore", dependencies: ["NotesCore"], linkerSettings: [
            .linkedLibrary("sqlite3"), .linkedFramework("PDFKit"), .linkedFramework("ImageIO"),
            .linkedFramework("AVFoundation"), .linkedFramework("AppKit"), .linkedFramework("PencilKit")
        ]),
        .target(name: "NotesIndex", dependencies: ["NotesCore"], linkerSettings: [.linkedLibrary("sqlite3")]),
        // macOS: writes through Notes.app scripting, verified by reading back.
        .target(name: "NotesAutomation", dependencies: ["NotesCore"]),
        // macOS: rich writes through NotesShared, loaded only at runtime.
        .target(name: "NotesNativeObjC", linkerSettings: [.linkedFramework("CoreData"), .linkedFramework("AppKit")]),
        .target(name: "NotesNative", dependencies: ["NotesCore", "NotesStore", "NotesNativeObjC"]),
        // MCP server over stdio, same operations as the CLI.
        // Write journal, snapshots/undo, and the write-folder allowlist.
        .target(name: "NotesSafety", dependencies: ["NotesCore"], linkerSettings: [.linkedLibrary("sqlite3")]),
        .target(name: "NotesMCP", dependencies: ["NotesCore", "NotesIndex", "NotesSafety", "NotesStore", "NotesSync"], linkerSettings: [
            .linkedFramework("ImageIO"), .linkedFramework("CoreGraphics")
        ]),
        .target(name: "NotesSync", dependencies: ["NotesCore"], linkerSettings: [
            .linkedLibrary("sqlite3"),
            .linkedFramework("CoreServices"),
        ]),
        .executableTarget(name: "notescli", dependencies: [
            "NotesCore", "NotesStore", "NotesIndex", "NotesAutomation", "NotesNative", "NotesMCP", "NotesSync", "NotesSafety",
            .product(name: "ArgumentParser", package: "swift-argument-parser"),
        ]),
        .testTarget(name: "NotesCoreTests", dependencies: ["NotesCore"]),
        .testTarget(name: "NotesStoreTests", dependencies: ["NotesStore", "NotesCore"]),
        .testTarget(name: "NotesIndexTests", dependencies: ["NotesIndex", "NotesStore", "NotesCore"]),
        .testTarget(name: "NotesAutomationTests", dependencies: ["NotesAutomation", "NotesCore"]),
        .testTarget(name: "NotesNativeTests", dependencies: ["NotesNative", "NotesAutomation", "NotesCore", "NotesStore"]),
        .testTarget(name: "NotesSafetyTests", dependencies: ["NotesSafety", "NotesCore"]),
        .testTarget(name: "NotesMCPTests", dependencies: ["NotesMCP", "NotesCore"]),
        .testTarget(name: "NotesSyncTests", dependencies: ["NotesSync", "NotesCore"]),
    ]
)
