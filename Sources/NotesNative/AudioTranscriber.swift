import AVFoundation
import Foundation
import NotesCore
import Speech

public final class PreparedRecording: @unchecked Sendable {
    public let url: URL
    public let duration: Double
    private let directory: URL

    fileprivate init(url: URL, duration: Double, directory: URL) {
        self.url = url
        self.duration = duration
        self.directory = directory
    }

    deinit { try? FileManager.default.removeItem(at: directory) }
}

public enum AudioTranscriber {
    static func requireSpeechUsageDescription(in bundle: Bundle = .main) throws {
        guard let value = bundle.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") as? String,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NotesError("speech_permission_unavailable",
                             "Speech Recognition is unavailable because this build has no NSSpeechRecognitionUsageDescription.",
                             hint: "Run the packaged notescli release.")
        }
    }

    public static var authorizationStatus: SFSpeechRecognizerAuthorizationStatus {
        SFSpeechRecognizer.authorizationStatus()
    }

    public static func requestAuthorization() async throws -> SFSpeechRecognizerAuthorizationStatus {
        try requireSpeechUsageDescription()
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
    }

    public static func prepare(_ source: URL, title: String? = nil) async throws -> PreparedRecording {
        let source = source.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw NotesError("invalid_file", "The audio file is not readable.")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("notescli-recording-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            let stem = safeStem(title ?? source.deletingPathExtension().lastPathComponent)
            let output = directory.appendingPathComponent(stem + ".m4a")
            let asset = AVURLAsset(url: source)
            let duration = try await asset.load(.duration).seconds
            guard duration.isFinite, duration > 0 else { throw NotesError("invalid_audio", "The audio file has no playable duration.") }
            guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
                throw NotesError("unsupported_audio", "AVFoundation cannot convert this audio file to M4A.")
            }
            if #available(macOS 15, *) {
                try await exporter.export(to: output, as: .m4a)
            } else {
                try await legacyExport(exporter, to: output)
            }
            return PreparedRecording(url: output, duration: duration, directory: directory)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw (error as? NotesError) ?? NotesError("audio_conversion_failed", "Could not convert the audio file: \(error.localizedDescription)")
        }
    }

    public static func transcribe(_ file: URL, locale identifier: String? = nil) async throws -> [TranscriptWord] {
        try requireSpeechUsageDescription()
        var status = authorizationStatus
        if status == .notDetermined { status = try await requestAuthorization() }
        guard status == .authorized else {
            throw NotesError("speech_permission_required", "Speech Recognition access is required. Run notescli permissions.")
        }
        let locale = Locale(identifier: identifier ?? Locale.current.identifier)
        if #available(macOS 26, *), SpeechTranscriber.isAvailable {
            if let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) {
                do { return try await modernTranscription(file, locale: supported) }
                catch let error as NotesError { throw error }
                catch { /* Use the on-device recognizer below. */ }
            }
        }
        return try await legacyTranscription(file, locale: locale)
    }

    public static func transcribeBlocking(_ file: URL, locale: String? = nil) throws -> [TranscriptWord] {
        let box = BlockingResult<[TranscriptWord]>()
        Task {
            do { box.set(.success(try await transcribe(file, locale: locale))) }
            catch { box.set(.failure(error)) }
        }
        return try box.wait()
    }

    public static func prepareBlocking(_ source: URL, title: String? = nil) throws -> PreparedRecording {
        let box = BlockingResult<PreparedRecording>()
        Task {
            do { box.set(.success(try await prepare(source, title: title))) }
            catch { box.set(.failure(error)) }
        }
        return try box.wait()
    }

    public static func requestAuthorizationBlocking() throws -> SFSpeechRecognizerAuthorizationStatus {
        let box = BlockingResult<SFSpeechRecognizerAuthorizationStatus>()
        Task {
            do { box.set(.success(try await requestAuthorization())) }
            catch { box.set(.failure(error)) }
        }
        return try box.wait()
    }

    @available(macOS 26, *)
    private static func modernTranscription(_ file: URL, locale: Locale) async throws -> [TranscriptWord] {
        let transcriber = SpeechTranscriber(locale: locale, preset: .timeIndexedTranscriptionWithAlternatives)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let resultTask = Task { () throws -> [TranscriptWord] in
            var segments: [TranscriptWord] = []
            for try await result in transcriber.results where result.isFinal {
                let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                segments.append(TranscriptWord(text: text, start: result.range.start.seconds,
                                               duration: result.range.duration.seconds, speaker: "Speaker 1", fragment: 0))
            }
            return segments
        }
        do {
            let audio = try AVAudioFile(forReading: file)
            _ = try await analyzer.analyzeSequence(from: audio)
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            let segments = try await resultTask.value
            guard !segments.isEmpty else { throw NotesError("transcription_empty", "On-device transcription returned no speech.") }
            return segments
        } catch {
            resultTask.cancel()
            throw error
        }
    }

    private static func legacyTranscription(_ file: URL, locale: Locale) async throws -> [TranscriptWord] {
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            throw NotesError("on_device_transcription_unavailable", "No on-device speech recognizer is available for \(locale.identifier).")
        }
        let request = SFSpeechURLRecognitionRequest(url: file)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        return try await withCheckedThrowingContinuation { continuation in
            let state = RecognitionState(continuation)
            state.setTask(recognizer.recognitionTask(with: request) { result, error in
                if let error { state.finish(.failure(NotesError("transcription_failed", error.localizedDescription))); return }
                guard let result, result.isFinal else { return }
                let segments = result.bestTranscription.segments.map {
                    TranscriptWord(text: $0.substring, start: $0.timestamp, duration: $0.duration,
                                   speaker: "Speaker 1", fragment: 0)
                }
                state.finish(segments.isEmpty
                    ? .failure(NotesError("transcription_empty", "On-device transcription returned no speech."))
                    : .success(segments))
            })
        }
    }

    @available(macOS, introduced: 10.7, obsoleted: 15)
    private static func legacyExport(_ exporter: AVAssetExportSession, to output: URL) async throws {
        exporter.outputURL = output
        exporter.outputFileType = .m4a
        await exporter.export()
        if let error = exporter.error { throw error }
        guard exporter.status == .completed else { throw NotesError("audio_conversion_failed", "AVFoundation did not complete the M4A conversion.") }
    }

    private static func safeStem(_ value: String) -> String {
        let cleaned = value.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Recording" : cleaned
    }
}

private final class BlockingResult<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Result<Value, Error>?
    func set(_ value: Result<Value, Error>) { lock.withLock { self.value = value } }
    func wait() throws -> Value {
        while true {
            if let result = lock.withLock({ value }) { return try result.get() }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
        }
    }
}

private final class RecognitionState: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<[TranscriptWord], Error>?
    private var task: SFSpeechRecognitionTask?

    init(_ continuation: CheckedContinuation<[TranscriptWord], Error>) { self.continuation = continuation }

    func setTask(_ task: SFSpeechRecognitionTask) {
        let keep = lock.withLock {
            guard continuation != nil else { return false }
            self.task = task
            return true
        }
        if !keep { task.cancel() }
    }

    func finish(_ result: Result<[TranscriptWord], Error>) {
        let continuation = lock.withLock { () -> CheckedContinuation<[TranscriptWord], Error>? in
            defer { self.continuation = nil }
            task = nil
            return self.continuation
        }
        guard let continuation else { return }
        switch result {
        case .success(let value): continuation.resume(returning: value)
        case .failure(let error): continuation.resume(throwing: error)
        }
    }
}
