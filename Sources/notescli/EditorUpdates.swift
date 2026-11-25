import AppKit
import NotesCore

enum EditorUpdates {
    private static let endpoint = URL(string: "https://api.github.com/repos/saikrishnabolla/NotesCLI/releases/latest")!

    private struct Release: Decodable {
        let tag_name: String
        let draft: Bool
        let prerelease: Bool
    }

    static func newerVersion(in data: Data, installed: String) throws -> String? {
        func version(_ value: String) -> [Int]? {
            let parts = value.split(separator: ".", omittingEmptySubsequences: false)
            let numbers = parts.compactMap { part -> Int? in
                guard !part.isEmpty, part.count == 1 || part.first != "0",
                      part.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
                return Int(part)
            }
            return parts.count == 3 && numbers.count == 3 ? numbers : nil
        }
        guard data.count <= 1_048_576,
              let release = try? JSONDecoder().decode(Release.self, from: data),
              release.tag_name.hasPrefix("v"),
              let latest = version(String(release.tag_name.dropFirst())),
              let current = version(installed), !release.draft, !release.prerelease else {
            throw NotesError("update_check_failed", "Could not check for Notes CLI updates.")
        }
        if current.lexicographicallyPrecedes(latest) { return latest.map(String.init).joined(separator: ".") }
        return nil
    }

    static func check() async throws -> String? {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 12
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(from: endpoint)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw NotesError("update_check_failed", "Could not check for Notes CLI updates.")
        }
        return try newerVersion(in: data, installed: notesCLIVersion)
    }

    private final class CheckResult: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Result<String?, Error>?

        func store(_ result: Result<String?, Error>) { lock.withLock { value = result } }
        func load() -> Result<String?, Error>? { lock.withLock { value } }
    }

    // ArgumentParser runs this command synchronously. Keep the network off the caller's executor.
    static func checkFromCLI() throws -> String? {
        let result = CheckResult()
        let complete = DispatchSemaphore(value: 0)
        let task = Task.detached {
            defer { complete.signal() }
            do { result.store(.success(try await check())) }
            catch { result.store(.failure(error)) }
        }
        guard complete.wait(timeout: .now() + 15) == .success,
              let reply = result.load(), case .success(let newer) = reply else {
            task.cancel()
            throw NotesError("update_check_failed", "Couldn’t check for Notes CLI updates. Try again later.")
        }
        return newer
    }
}

@MainActor
final class EditorUpdateChecks {
    private var timer: Timer?
    private var pending: Task<Void, Never>?
    private var announceResult = false
    private var announcedVersion: String?

    func startAutomaticChecks() {
        guard timer == nil else { return }
        check(manual: false)
        timer = Timer.scheduledTimer(withTimeInterval: 86_400, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check(manual: false) }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        pending?.cancel()
        pending = nil
    }

    func check(manual: Bool) {
        if manual { announceResult = true }
        guard pending == nil else { return }
        pending = Task { [weak self] in
            let result: Result<String?, Error>
            do { result = .success(try await EditorUpdates.check()) }
            catch { result = .failure(error) }
            guard !Task.isCancelled, let self else { return }
            finish(result)
        }
    }

    private func finish(_ result: Result<String?, Error>) {
        pending = nil
        let manual = announceResult
        announceResult = false
        let alert = NSAlert()
        switch result {
        case .success(let version?):
            guard manual || version != announcedVersion else { return }
            announcedVersion = version
            alert.messageText = "Notes CLI \(version) is available"
            alert.informativeText = "If you installed with Homebrew, run brew upgrade notescli in Terminal."
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "View Release")
            NSApp.activate()
            if alert.runModal() == .alertSecondButtonReturn,
               let url = URL(string: "https://github.com/saikrishnabolla/NotesCLI/releases/tag/v\(version)") {
                NSWorkspace.shared.open(url)
            }
            return
        case .success(nil):
            guard manual else { return }
            alert.messageText = "Notes CLI is up to date"
        case .failure:
            guard manual else { return }
            alert.messageText = "Couldn’t check for updates"
            alert.informativeText = "Try again later."
        }
        NSApp.activate()
        alert.runModal()
    }
}
