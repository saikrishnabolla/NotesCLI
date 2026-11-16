import Foundation

struct CLICommandResult: Sendable {
    let exitCode: Int32
    let standardOutput: String
    let standardError: String

    var combinedOutput: String {
        [standardOutput, standardError]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}

enum CLIProcessError: LocalizedError {
    case failedToLaunch(String)
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .failedToLaunch(let message), .commandFailed(let message): message
        }
    }
}

final class CLIProcessRunner: @unchecked Sendable {
    let executableURL: URL

    init(executableURL: URL) {
        self.executableURL = executableURL
    }

    func run(_ arguments: [String]) async throws -> CLICommandResult {
        try await withCheckedThrowingContinuation { continuation in
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("notes-cli-command-\(UUID().uuidString)", isDirectory: true)
            do {
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700]
                )
                let outputURL = directory.appendingPathComponent("stdout")
                let errorURL = directory.appendingPathComponent("stderr")
                FileManager.default.createFile(atPath: outputURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
                FileManager.default.createFile(atPath: errorURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
                let output = try FileHandle(forWritingTo: outputURL)
                let error = try FileHandle(forWritingTo: errorURL)

                let process = Process()
                process.executableURL = executableURL
                process.arguments = arguments
                process.standardInput = FileHandle.nullDevice
                process.standardOutput = output
                process.standardError = error
                process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
                var environment = ProcessInfo.processInfo.environment
                environment["NOTESCLI_CAPABILITY_HOST"] = "direct"
                environment["NOTESCLI_HOST_ACTIVE"] = "1"
                process.environment = environment
                process.terminationHandler = { process in
                    do {
                        try output.close()
                        try error.close()
                        let standardOutput = String(decoding: try Data(contentsOf: outputURL), as: UTF8.self)
                        let standardError = String(decoding: try Data(contentsOf: errorURL), as: UTF8.self)
                        try? FileManager.default.removeItem(at: directory)
                        continuation.resume(returning: CLICommandResult(
                            exitCode: process.terminationStatus,
                            standardOutput: standardOutput,
                            standardError: standardError
                        ))
                    } catch {
                        try? FileManager.default.removeItem(at: directory)
                        continuation.resume(throwing: CLIProcessError.failedToLaunch(error.localizedDescription))
                    }
                }
                try process.run()
            } catch {
                try? FileManager.default.removeItem(at: directory)
                continuation.resume(throwing: CLIProcessError.failedToLaunch(error.localizedDescription))
            }
        }
    }

    func requireSuccess(_ arguments: [String]) async throws -> CLICommandResult {
        let result = try await run(arguments)
        guard result.exitCode == 0 else {
            throw CLIProcessError.commandFailed(result.combinedOutput.isEmpty ? "Notes CLI could not complete the action." : result.combinedOutput)
        }
        return result
    }
}
