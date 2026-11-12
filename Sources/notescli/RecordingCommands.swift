import ArgumentParser
import Foundation
import NotesCore
import NotesNative
import NotesSafety

struct RecordingCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "recording",
        abstract: "Create, transcribe, and read native Apple Notes recordings.",
        subcommands: [RecordingAdd.self, RecordingCreate.self, RecordingTranscribeFile.self, RecordingTranscribe.self, RecordingTranscriptCommand.self]
    )
}

struct RecordingAdd: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "add", abstract: "Add a native recording to a note.")
    @OptionGroup var options: GlobalOptions
    @OptionGroup var write: WriteOptions
    @Argument var note: String
    @Option(help: "Audio file (MP3, WAV, AAC, M4A, or another AVFoundation input).") var file: String
    @Flag(help: "Transcribe on device and store the native Notes transcript.") var transcribe = false
    @Option(help: "Import timed transcript JSON instead of transcribing on device.") var transcriptFile: String?
    @Option(help: "Recording title.") var title: String?
    @Option(help: "Speech locale, such as en-US.") var locale: String?

    func validate() throws { try validateTranscriptSource(transcribe: transcribe, transcriptFile: transcriptFile) }

    func run() throws {
        let backend = try options.writable()
        _ = try UnifiedNative.engine(options, scriptingAvailable: false, fake: backend.isFake)
        _ = try backend.reader.summary(note)
        let source = try InputFile.validated(URL(fileURLWithPath: NSString(string: file).expandingTildeInPath),
                                             kind: "audio file", maxBytes: AudioTranscriber.maxAudioBytes)
        let prepared = write.dryRun ? nil : try AudioTranscriber.prepareBlocking(source, title: title)
        let segments = try recordingTranscriptSegments(transcribe: transcribe, transcriptFile: transcriptFile,
                                                       audio: prepared?.url, locale: locale, dryRun: write.dryRun)
        let frozen = try prepared.map { try FrozenAttachmentInput(file: $0.url) }
        try UnifiedNative.noteWrite(options: options, write: write, ref: note, operation: "recordingAdd",
                                    arguments: ["file": source.path, "title": title ?? "", "transcribe": String(transcribe),
                                                "transcriptFile": transcriptFile ?? ""]) { stableRef in
            guard let prepared, let frozen else { preconditionFailure("Dry runs do not execute writes") }
            return NativeActionResult(try NativeNotesWriter().insertRecording(stableRef, frozen: frozen, title: title,
                                                                               duration: prepared.duration, transcript: segments,
                                                                               allowShared: write.allowShared))
        }
    }
}

struct RecordingCreate: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create", abstract: "Create a note containing a native recording.")
    @OptionGroup var options: GlobalOptions
    @OptionGroup var write: WriteOptions
    @Option(help: "Destination folder.") var folder: String
    @Option(help: "Note title.") var title: String
    @Option(help: "Audio file (MP3, WAV, AAC, M4A, or another AVFoundation input).") var file: String
    @Flag(help: "Transcribe on device and store the native Notes transcript.") var transcribe = false
    @Option(help: "Import timed transcript JSON instead of transcribing on device.") var transcriptFile: String?
    @Option(help: "Speech locale, such as en-US.") var locale: String?

    func validate() throws { try validateTranscriptSource(transcribe: transcribe, transcriptFile: transcriptFile) }

    func run() throws {
        let backend = try options.writable()
        _ = try UnifiedNative.engine(options, scriptingAvailable: false, fake: backend.isFake)
        let source = try InputFile.validated(URL(fileURLWithPath: NSString(string: file).expandingTildeInPath),
                                             kind: "audio file", maxBytes: AudioTranscriber.maxAudioBytes)
        let targetPath = try SafetyExecutor.folderPath(folder, reader: backend.reader)
        let plan = DryRunPlan(operation: "recordingCreate", target: title,
                              arguments: ["folder": folder, "file": source.path, "transcribe": String(transcribe),
                                          "transcriptFile": transcriptFile ?? ""],
                              resultingHTML: SafetyExecutor.bodyHTML(title: title, markdown: ""), engine: "native")
        let prepared = write.dryRun ? nil : try AudioTranscriber.prepareBlocking(source, title: title)
        let segments = try recordingTranscriptSegments(transcribe: transcribe, transcriptFile: transcriptFile,
                                                       audio: prepared?.url, locale: locale, dryRun: write.dryRun)
        let frozen = try prepared.map { try FrozenAttachmentInput(file: $0.url) }
        var captured: NativeRecordingResult?
        let result = try SafetyExecutor.run(options: write, operation: "recordingCreate",
            arguments: ["title": title, "folder": folder, "file": source.path, "transcribe": String(transcribe),
                        "transcriptFile": transcriptFile ?? "", "engine": "native"],
            allowedPaths: targetPath.map { [$0] } ?? [], plan: plan) {
                guard let prepared, let frozen else { preconditionFailure("Dry runs do not execute writes") }
                let value = try NativeNotesWriter().createRecordingNote(folder: folder, title: title, frozen: frozen,
                                                                         duration: prepared.duration, transcript: segments,
                                                                         allowShared: write.allowShared)
                captured = value
                return value.write.writeResult
            }
        guard let result else { return }
        let details = captured.map { ["attachment_id": $0.attachmentID, "fragment_ids": $0.childAttachmentIDs.joined(separator: ","),
                                      "duration": String($0.duration), "transcript_segments": String($0.transcriptSegments)] }
        try outputEngineWrite(EngineWriteResponse(engine: "native", result: result, operationID: captured?.write.operationID,
                                                  verification: captured?.write.verification, details: details), options: options)
    }
}

struct RecordingTranscribeFile: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "transcribe-file", abstract: "Transcribe an audio file to timed JSON without opening Notes.")
    @Option(help: "Audio file to transcribe.") var file: String
    @Option(help: "JSON output file.") var output: String
    @Option(help: "Speech locale, such as en-US.") var locale: String?

    func run() throws {
        let source = try InputFile.validated(URL(fileURLWithPath: NSString(string: file).expandingTildeInPath),
                                             kind: "audio file", maxBytes: AudioTranscriber.maxAudioBytes)
        let destination = URL(fileURLWithPath: NSString(string: output).expandingTildeInPath)
        let prepared = try AudioTranscriber.prepareBlocking(source)
        let segments = try AudioTranscriber.transcribeBlocking(prepared.url, locale: locale)
        let transcript = AudioTranscriptFile(locale: locale ?? Locale.current.identifier, segments: segments)
        do { try AudioTranscriber.encodeTranscriptFile(transcript).write(to: destination, options: .atomic) }
        catch let error as NotesError { throw error }
        catch { throw NotesError("transcript_output_failed", "Could not write the transcript file: \(error.localizedDescription)") }
        print(destination.path)
    }
}

struct RecordingTranscribe: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "transcribe", abstract: "Transcribe native recordings that lack a transcript.")
    @OptionGroup var options: GlobalOptions
    @OptionGroup var write: WriteOptions
    @Argument var note: String
    @Option(name: .customLong("attachment"), help: "Transcribe one recording attachment ID.") var attachmentID: String?
    @Option(help: "Speech locale, such as en-US.") var locale: String?
    @Option(help: "Import timed transcript JSON for one recording instead of transcribing on device.") var transcriptFile: String?

    func run() throws {
        let backend = try options.writable()
        _ = try UnifiedNative.engine(options, scriptingAvailable: false, fake: backend.isFake)
        let loaded = try backend.reader.note(note)
        var recordings = loaded.attachments.filter { ($0.childAttachmentIDs?.isEmpty == false) && ($0.transcriptWords?.isEmpty != false) }
        if let attachmentID { recordings = recordings.filter { $0.id.caseInsensitiveCompare(attachmentID) == .orderedSame } }
        guard !recordings.isEmpty else { throw NotesError("recording_not_found", "No matching recording without a transcript was found.") }
        if transcriptFile != nil, recordings.count != 1 {
            throw NotesError("invalid_transcript_file", "--transcript-file requires exactly one matching recording; use --attachment.")
        }
        var transcripts: [String: [TranscriptWord]] = [:]
        if !write.dryRun {
            if let transcriptFile {
                let url = URL(fileURLWithPath: NSString(string: transcriptFile).expandingTildeInPath)
                transcripts[recordings[0].id] = try AudioTranscriber.readTranscriptFile(url).segments
            } else {
                for recording in recordings {
                    transcripts[recording.id] = try AudioTranscriber.transcribeRecordingBlocking(recording, locale: locale)
                }
            }
        }
        try UnifiedNative.noteWrite(options: options, write: write, ref: loaded.summary.id.uuid, operation: "recordingTranscribe",
                                    arguments: ["attachment": attachmentID ?? "", "locale": locale ?? "",
                                                "transcriptFile": transcriptFile ?? ""]) { stableRef in
            NativeActionResult(try NativeNotesWriter().writeRecordingTranscripts(stableRef, transcripts: transcripts,
                                                                                  allowShared: write.allowShared))
        }
    }
}

struct RecordingTranscriptCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "transcript", abstract: "Print native recording transcripts.")
    @OptionGroup var options: GlobalOptions
    @Argument var note: String
    @Option(help: "Output format: text, srt, vtt, or json.") var format: RecordingTranscriptFormat = .text

    func run() throws {
        let loaded = try options.backends().reader.note(note)
        let recordings = loaded.attachments.filter { $0.childAttachmentIDs?.isEmpty == false }.map {
            RecordingTranscript(attachmentID: $0.id, duration: $0.duration, segments: $0.transcriptWords ?? [])
        }
        guard !recordings.isEmpty else { throw NotesError("recording_not_found", "The note has no native recordings.") }
        print(try RecordingTranscriptRenderer.render(recordings, format: format), terminator: "")
    }
}

extension RecordingTranscriptFormat: ExpressibleByArgument {}

private func validateTranscriptSource(transcribe: Bool, transcriptFile: String?) throws {
    if transcribe, transcriptFile != nil { throw ValidationError("Choose --transcribe or --transcript-file, not both.") }
}

private func recordingTranscriptSegments(transcribe: Bool, transcriptFile: String?, audio: URL?, locale: String?, dryRun: Bool) throws -> [TranscriptWord] {
    if let transcriptFile {
        // Dry runs read and validate the transcript too, so a bad path fails before any write is planned.
        let url = URL(fileURLWithPath: NSString(string: transcriptFile).expandingTildeInPath)
        let segments = try AudioTranscriber.readTranscriptFile(url).segments
        return dryRun ? [] : segments
    }
    guard !dryRun else { return [] }
    guard transcribe, let audio else { return [] }
    return try AudioTranscriber.transcribeBlocking(audio, locale: locale)
}
