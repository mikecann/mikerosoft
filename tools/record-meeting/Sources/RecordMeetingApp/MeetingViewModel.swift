import AppKit
import Foundation

@MainActor
final class MeetingViewModel: ObservableObject {
    @Published var title = ""
    @Published var meetingDescription = ""
    @Published private(set) var isRecording = false
    @Published private(set) var isProcessing = false
    @Published private(set) var startedAt: Date?
    @Published private(set) var statusMessage = "Ready to record"
    @Published var presentedError: String?
    @Published var pendingMeeting: ProcessedMeeting?
    @Published private(set) var lastNotionURL: URL?
    @Published private(set) var recordingWaveform: [Double] = []

    let preferences: RecordMeetingPreferences
    private let recorder: MeetingRecorder
    private let processor: MeetingProcessor
    private let keychain: KeychainStore
    private var activeRawURL: URL?
    private var activeFileStem: String?
    private var capturedWaveform: [Double] = []

    init(
        preferences: RecordMeetingPreferences = RecordMeetingPreferences(),
        recorder: MeetingRecorder = MeetingRecorder(),
        processor: MeetingProcessor = MeetingProcessor(),
        keychain: KeychainStore = KeychainStore()
    ) {
        self.preferences = preferences
        self.recorder = recorder
        self.processor = processor
        self.keychain = keychain
        recorder.setAudioLevelHandler { [weak self] level in
            Task { @MainActor in
                self?.receiveAudioLevel(level)
            }
        }
    }

    var isBusy: Bool { isRecording || isProcessing }

    func startRecording() async {
        guard !isBusy else { return }
        let now = Date()
        let resolvedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if resolvedTitle.isEmpty {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            title = "Meeting \(formatter.string(from: now))"
        }
        let stem = MeetingFiles.fileStem(title: title, startedAt: now)
        let directory = URL(fileURLWithPath: preferences.saveDirectory, isDirectory: true)
        let rawURL = directory.appendingPathComponent(".\(stem)-capture.mov")

        do {
            capturedWaveform = []
            recordingWaveform = []
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            try? FileManager.default.removeItem(at: rawURL)
            statusMessage = "Starting system audio and microphone…"
            try await recorder.start(outputURL: rawURL)
            startedAt = now
            activeRawURL = rawURL
            activeFileStem = stem
            isRecording = true
            statusMessage = "Recording system audio and microphone"
        } catch {
            statusMessage = "Could not start recording"
            presentedError = error.localizedDescription
        }
    }

    func stopRecording() async {
        guard isRecording,
              let rawURL = activeRawURL,
              let stem = activeFileStem,
              let startedAt else { return }

        isRecording = false
        isProcessing = true
        recordingWaveform = WaveformMath.resample(capturedWaveform, targetCount: 240)
        statusMessage = "Finishing the recording…"
        let endedAt = Date()

        do {
            try await recorder.stop()
            statusMessage = "Transcribing and detecting speakers…"
            let directory = URL(fileURLWithPath: preferences.saveDirectory, isDirectory: true)
            let result = try await processor.process(
                rawCaptureURL: rawURL,
                outputDirectory: directory,
                fileStem: stem,
                whisperModel: preferences.whisperModel,
                huggingFaceToken: keychain.read(.huggingFaceToken)
            )

            let markdownURL = directory
                .appendingPathComponent("\(stem).transcript")
                .appendingPathExtension("md")
            let metadataURL = directory
                .appendingPathComponent("\(stem).metadata")
                .appendingPathExtension("json")
            pendingMeeting = ProcessedMeeting(
                document: result.document,
                rawCaptureURL: rawURL,
                audioURL: result.audioURL,
                transcriptJSONURL: result.transcriptJSONURL,
                transcriptMarkdownURL: markdownURL,
                metadataURL: metadataURL,
                startedAt: startedAt,
                endedAt: endedAt,
                title: title,
                description: meetingDescription,
                waveformSamples: capturedWaveform
            )
            statusMessage = "Name the detected speakers"
        } catch {
            statusMessage = "Recording saved, but processing needs attention"
            presentedError = "\(error.localizedDescription)\n\nThe temporary recording was kept at:\n\(rawURL.path)"
        }

        isProcessing = false
        self.startedAt = nil
        activeRawURL = nil
        activeFileStem = nil
    }

    private func receiveAudioLevel(_ level: Double) {
        guard isRecording else { return }
        capturedWaveform.append(level)
        // Three hours at 20 samples per second is still a small array, and
        // retaining it gives the completed review a full-meeting waveform.
        if capturedWaveform.count > 216_000 {
            capturedWaveform.removeFirst(capturedWaveform.count - 216_000)
        }
        recordingWaveform = Array(capturedWaveform.suffix(96))
    }

    func finalizeSpeakerNames(_ names: [String: String]) async {
        guard let pendingMeeting else { return }
        isProcessing = true
        statusMessage = "Saving transcript and metadata…"

        let normalizedNames = Dictionary(uniqueKeysWithValues: pendingMeeting.document.speakers.map {
            let entered = names[$0.id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return ($0.id, entered.isEmpty
                ? TranscriptDocument.displayName(for: $0.id, names: [:])
                : entered)
        })
        let speakerList = pendingMeeting.document.speakers.map {
            TranscriptDocument.displayName(for: $0.id, names: normalizedNames)
        }
        let metadata = MeetingMetadata(
            id: UUID(),
            title: pendingMeeting.title,
            description: pendingMeeting.description,
            startedAt: pendingMeeting.startedAt,
            endedAt: pendingMeeting.endedAt,
            audioFile: pendingMeeting.audioURL.path,
            transcriptFile: pendingMeeting.transcriptMarkdownURL.path,
            speakers: speakerList
        )

        do {
            let markdown = pendingMeeting.document.markdown(
                title: pendingMeeting.title,
                description: pendingMeeting.description,
                startedAt: pendingMeeting.startedAt,
                endedAt: pendingMeeting.endedAt,
                speakerNames: normalizedNames
            )
            try Data(markdown.utf8).write(to: pendingMeeting.transcriptMarkdownURL, options: .atomic)

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(metadata).write(to: pendingMeeting.metadataURL, options: .atomic)

            lastNotionURL = nil
            if preferences.autoPublishToNotion {
                let notionToken = keychain.read(.notionToken)
                let sourceID = preferences.notionDataSourceID.trimmingCharacters(in: .whitespacesAndNewlines)
                if !notionToken.isEmpty, !sourceID.isEmpty {
                    statusMessage = "Publishing meeting to Notion…"
                    lastNotionURL = try await NotionClient(token: notionToken).publish(
                        meeting: metadata,
                        transcript: pendingMeeting.document,
                        speakerNames: normalizedNames,
                        dataSourceID: sourceID
                    )
                    statusMessage = "Saved locally and published to Notion"
                } else {
                    statusMessage = "Saved locally. Configure Notion in Preferences to publish."
                }
            } else {
                statusMessage = "Saved locally"
            }

            self.pendingMeeting = nil
            NSWorkspace.shared.activateFileViewerSelecting([
                pendingMeeting.audioURL,
                pendingMeeting.transcriptMarkdownURL,
            ])
        } catch {
            statusMessage = "Could not finish the meeting"
            presentedError = error.localizedDescription
        }
        isProcessing = false
    }

    func notionToken() -> String { keychain.read(.notionToken) }
    func huggingFaceToken() -> String { keychain.read(.huggingFaceToken) }

    func saveSecrets(notionToken: String, huggingFaceToken: String) throws {
        try keychain.write(notionToken, for: .notionToken)
        try keychain.write(huggingFaceToken, for: .huggingFaceToken)
    }

    func createNotionDatabase(notionToken: String) async throws {
        let token = notionToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            throw RecordMeetingError.message("Add your Notion integration token first.")
        }
        let sourceID = try await NotionClient(token: token).createRecordedMeetingsDatabase(
            parentPageReference: preferences.notionParentPage
        )
        preferences.notionDataSourceID = sourceID
        try keychain.write(token, for: .notionToken)
    }
}
