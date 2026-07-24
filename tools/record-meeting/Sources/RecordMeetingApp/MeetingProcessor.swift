import Foundation

struct MeetingProcessor: Sendable {
    func process(
        rawCaptureURL: URL,
        outputDirectory: URL,
        fileStem: String,
        whisperModel: String,
        huggingFaceToken: String
    ) async throws -> (document: TranscriptDocument, audioURL: URL, transcriptJSONURL: URL) {
        let resources = Bundle.main.resourceURL
        let script = resources?.appendingPathComponent("record_meeting_processor.py")
        guard let script, FileManager.default.fileExists(atPath: script.path) else {
            throw RecordMeetingError.message("The bundled transcription processor is missing. Reinstall Record Meeting.")
        }

        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        let venvPython = applicationSupport
            .appendingPathComponent("Record Meeting/venv/bin/python3")

        let process = Process()
        if FileManager.default.isExecutableFile(atPath: venvPython.path) {
            process.executableURL = venvPython
            process.arguments = processorArguments(
                script: script,
                rawCaptureURL: rawCaptureURL,
                outputDirectory: outputDirectory,
                fileStem: fileStem,
                whisperModel: whisperModel
            )
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["python3"] + processorArguments(
                script: script,
                rawCaptureURL: rawCaptureURL,
                outputDirectory: outputDirectory,
                fileStem: fileStem,
                whisperModel: whisperModel
            )
        }

        var environment = ProcessInfo.processInfo.environment
        environment["HF_TOKEN"] = huggingFaceToken
        process.environment = environment

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        try process.run()
        let data = try await readToEnd(outputPipe.fileHandleForReading)
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)

        guard process.terminationStatus == 0 else {
            throw RecordMeetingError.message(
                output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "Transcription failed with exit code \(process.terminationStatus)."
                    : output.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        let audioURL = outputDirectory.appendingPathComponent(fileStem).appendingPathExtension("mp3")
        let jsonURL = outputDirectory
            .appendingPathComponent("\(fileStem).transcript")
            .appendingPathExtension("json")
        let document = try JSONDecoder().decode(
            TranscriptDocument.self,
            from: Data(contentsOf: jsonURL)
        )
        try? FileManager.default.removeItem(at: rawCaptureURL)
        return (document, audioURL, jsonURL)
    }

    private func processorArguments(
        script: URL,
        rawCaptureURL: URL,
        outputDirectory: URL,
        fileStem: String,
        whisperModel: String
    ) -> [String] {
        [
            script.path,
            "--input", rawCaptureURL.path,
            "--output-dir", outputDirectory.path,
            "--stem", fileStem,
            "--model", whisperModel,
        ]
    }

    private func readToEnd(_ handle: FileHandle) async throws -> Data {
        try await Task.detached(priority: .utility) {
            try handle.readToEnd() ?? Data()
        }.value
    }
}
