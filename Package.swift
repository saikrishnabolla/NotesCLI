// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "notectl",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "notectl", targets: ["notectl"]),
        .library(name: "NotesCore", targets: ["NotesCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        // Pure Swift: model, protobuf decoding, renderers. No Apple frameworks, so it builds on Linux.
        .target(name: "NotesCore"),
        // macOS: read-only NoteStore.sqlite snapshot reader.
        .target(name: "NotesStore", dependencies: ["NotesCore"], linkerSettings: [.linkedLibrary("sqlite3")]),
        // macOS: writes through Notes.app scripting, verified by reading back.
        .target(name: "NotesAutomation", dependencies: ["NotesCore"]),
        // MCP server over stdio, same operations as the CLI.
        .target(name: "NotesMCP", dependencies: ["NotesCore"]),
        .executableTarget(name: "notectl", dependencies: [
            "NotesCore", "NotesStore", "NotesAutomation", "NotesMCP",
            .product(name: "ArgumentParser", package: "swift-argument-parser"),
        ]),
        .testTarget(name: "NotesCoreTests", dependencies: ["NotesCore"]),
        .testTarget(name: "NotesStoreTests", dependencies: ["NotesStore", "NotesCore"]),
        .testTarget(name: "NotesAutomationTests", dependencies: ["NotesAutomation", "NotesCore"]),
        .testTarget(name: "NotesMCPTests", dependencies: ["NotesMCP", "NotesCore"]),
    ]
)
