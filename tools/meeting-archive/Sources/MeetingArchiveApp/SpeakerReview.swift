import AVFoundation
import AVKit
import Combine
import Foundation
import MeetingArchiveCore
import SwiftUI

struct SpeakerReviewResponse: Codable, Equatable, Sendable {
    var schemaVersion: Int
    var meetingID: UUID
    var manifestRevision: Int
    var speakers: [SpeakerReviewSpeaker]
    var calendarCandidates: [SpeakerCalendarCandidate]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case meetingID = "meeting_id"
        case manifestRevision = "manifest_revision"
        case speakers
        case calendarCandidates = "calendar_candidates"
    }

    func validate(meetingID expectedMeetingID: UUID, revision expectedRevision: Int) throws {
        guard schemaVersion == 1, meetingID == expectedMeetingID, manifestRevision == expectedRevision else {
            throw SpeakerReviewError.invalidResponse("review-speakers returned the wrong meeting or revision")
        }
        guard Set(speakers.map(\.speakerID)).count == speakers.count else {
            throw SpeakerReviewError.invalidResponse("review-speakers returned duplicate speaker IDs")
        }
        for speaker in speakers {
            guard !speaker.speakerID.isEmpty else {
                throw SpeakerReviewError.invalidResponse("review-speakers returned an empty speaker ID")
            }
            for excerpt in speaker.excerpts {
                guard SpeakerPlaybackRange(start: excerpt.start, end: excerpt.end) != nil else {
                    throw SpeakerReviewError.invalidResponse("review-speakers returned an invalid excerpt range")
                }
            }
        }
    }
}

struct SpeakerReviewSpeaker: Codable, Equatable, Identifiable, Sendable {
    var speakerID: String
    var name: String?
    var suggestedName: String?
    var suggestionScore: Double?
    var suggestionMargin: Double?
    var embeddingAvailable: Bool
    var excerpts: [SpeakerReviewExcerpt]

    var id: String { speakerID }

    enum CodingKeys: String, CodingKey {
        case speakerID = "speaker_id"
        case name
        case suggestedName = "suggested_name"
        case suggestionScore = "suggestion_score"
        case suggestionMargin = "suggestion_margin"
        case embeddingAvailable = "embedding_available"
        case excerpts
    }
}

struct SpeakerReviewExcerpt: Codable, Equatable, Identifiable, Sendable {
    var start: Double
    var end: Double
    var text: String
    var channelOrigin: String
    var playbackPath: String?

    var id: String { "\(start)-\(end)-\(text)" }

    enum CodingKeys: String, CodingKey {
        case start, end, text
        case channelOrigin = "channel_origin"
        case playbackPath = "playback_path"
    }
}

struct SpeakerCalendarCandidate: Codable, Equatable, Identifiable, Sendable {
    var name: String
    var email: String?
    var responseStatus: String?
    var source: String?

    var id: String { "\(name)\u{0}\(email ?? "")" }

    enum CodingKeys: String, CodingKey {
        case name, email, source
        case responseStatus = "response_status"
    }
}

struct SpeakerIdentificationResponse: Codable, Equatable, Sendable {
    var schemaVersion: Int
    var confirmed: Bool
    var meetingID: UUID
    var manifestRevision: Int
    var speakerID: String
    var name: String
    var voiceProfileEnrolled: Bool

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case confirmed
        case meetingID = "meeting_id"
        case manifestRevision = "manifest_revision"
        case speakerID = "speaker_id"
        case name
        case voiceProfileEnrolled = "voice_profile_enrolled"
    }
}

struct LocatedSpeakerArchive: Codable, Equatable, Sendable {
    var schemaVersion: Int
    var meetingID: UUID
    var archivePath: String

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case meetingID = "meeting_id"
        case archivePath = "archive_path"
    }

    func validate(meetingID expectedMeetingID: UUID, configuration: ArchiveTransferConfiguration) throws {
        let safeCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "/._-"))
        guard schemaVersion == 1,
              meetingID == expectedMeetingID,
              archivePath.hasPrefix(configuration.archiveRoot + "/"),
              !archivePath.contains(".."),
              archivePath.unicodeScalars.allSatisfy({ safeCharacters.contains($0) })
        else {
            throw SpeakerReviewError.invalidResponse("locate returned an unsafe archive path")
        }
    }
}

struct SpeakerPlaybackRange: Equatable, Sendable {
    var start: Double
    var end: Double

    init?(start: Double, end: Double) {
        guard start.isFinite, end.isFinite else { return nil }
        let clampedStart = max(0, start)
        guard end > clampedStart else { return nil }
        self.start = clampedStart
        self.end = end
    }
}

@MainActor
enum SpeakerPlayerSurface {
    static func make(player: AVPlayer) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = false
        view.showsSharingServiceButton = false
        return view
    }

    static func update(_ view: AVPlayerView, player: AVPlayer) {
        if view.player !== player { view.player = player }
    }

    static func dismantle(_ view: AVPlayerView) {
        view.player?.pause()
        view.player = nil
    }
}

@MainActor
struct SpeakerPlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        SpeakerPlayerSurface.make(player: player)
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        SpeakerPlayerSurface.update(view, player: player)
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        SpeakerPlayerSurface.dismantle(view)
    }
}

struct SpeakerReviewDraft: Equatable, Sendable {
    var name: String
    var isPredicted: Bool

    static func make(speakers: [SpeakerReviewSpeaker]) -> [String: SpeakerReviewDraft] {
        Dictionary(uniqueKeysWithValues: speakers.map { speaker in
            if let name = speaker.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                return (speaker.speakerID, SpeakerReviewDraft(name: name, isPredicted: false))
            }
            if let suggestion = speaker.suggestedName?.trimmingCharacters(in: .whitespacesAndNewlines), !suggestion.isEmpty {
                return (speaker.speakerID, SpeakerReviewDraft(name: suggestion, isPredicted: true))
            }
            return (speaker.speakerID, SpeakerReviewDraft(name: "", isPredicted: false))
        })
    }
}

enum SpeakerReviewError: Error, Equatable, CustomStringConvertible, LocalizedError {
    case invalidResponse(String)
    case emptyName

    var description: String {
        switch self {
        case .invalidResponse(let message): message
        case .emptyName: "Enter a speaker name before confirming it."
        }
    }

    var errorDescription: String? { description }
}

enum RemoteShellCommand {
    /// OpenSSH sends its trailing arguments through the remote login shell.
    /// Quote every argument before joining so names cannot become shell syntax.
    static func make(_ arguments: [String]) -> String {
        arguments.map(quote).joined(separator: " ")
    }

    static func quote(_ argument: String) -> String {
        "'" + argument.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}

enum SpeakerReviewCommandBuilder {
    static func locate(
        meetingID: UUID,
        configuration: ArchiveTransferConfiguration
    ) throws -> ArchiveProcessRequest {
        try configuration.validate()
        return remoteRequest(
            arguments: workerPrefix(configuration) + [
                "locate",
                "--meeting-id", meetingID.uuidString.lowercased(),
                "--archive-root", configuration.archiveRoot,
                "--db", configuration.workerDatabase,
            ],
            timeout: configuration.commandTimeout,
            configuration: configuration
        )
    }

    static func review(
        archivePath: String,
        revision: Int,
        configuration: ArchiveTransferConfiguration
    ) throws -> ArchiveProcessRequest {
        try configuration.validate()
        guard revision >= 1 else { throw SpeakerReviewError.invalidResponse("Revision must be at least one") }
        return remoteRequest(
            arguments: workerPrefix(configuration) + [
                "review-speakers",
                "--archive-dir", archivePath,
                "--revision", String(revision),
                "--db", configuration.workerDatabase,
            ],
            timeout: configuration.workerTimeout,
            configuration: configuration
        )
    }

    static func identify(
        meetingID: UUID,
        revision: Int,
        speakerID: String,
        name: String,
        configuration: ArchiveTransferConfiguration
    ) throws -> ArchiveProcessRequest {
        try configuration.validate()
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard revision >= 1 else { throw SpeakerReviewError.invalidResponse("Revision must be at least one") }
        guard !trimmedName.isEmpty else { throw SpeakerReviewError.emptyName }
        return remoteRequest(
            arguments: workerPrefix(configuration) + [
                "identify",
                "--meeting-id", meetingID.uuidString.lowercased(),
                "--revision", String(revision),
                "--speaker-id", speakerID,
                "--name", trimmedName,
                "--db", configuration.workerDatabase,
            ],
            timeout: configuration.commandTimeout,
            configuration: configuration
        )
    }

    private static func workerPrefix(_ configuration: ArchiveTransferConfiguration) -> [String] {
        [configuration.workerPython, configuration.workerScript]
    }

    private static func remoteRequest(
        arguments: [String],
        timeout: TimeInterval,
        configuration: ArchiveTransferConfiguration
    ) -> ArchiveProcessRequest {
        ArchiveProcessRequest(
            executable: configuration.sshExecutable,
            arguments: [
                "-o", "BatchMode=yes",
                "-o", "ConnectTimeout=5",
                "--", configuration.host,
                RemoteShellCommand.make(arguments),
            ],
            timeout: timeout
        )
    }
}

protocol SpeakerReviewServing: Sendable {
    func load(
        meetingID: UUID,
        revision: Int,
        configuration: ArchiveTransferConfiguration
    ) async throws -> SpeakerReviewResponse

    func identify(
        meetingID: UUID,
        revision: Int,
        speakerID: String,
        name: String,
        configuration: ArchiveTransferConfiguration
    ) async throws -> SpeakerIdentificationResponse

    func fetchPlayback(
        meetingID: UUID,
        destination: URL,
        configuration: ArchiveTransferConfiguration
    ) async throws -> URL
}

actor SpeakerReviewClient: SpeakerReviewServing {
    private let processRunner: any ArchiveProcessRunning
    private let transfer: ArchiveTransfer

    init(processRunner: any ArchiveProcessRunning = FoundationArchiveProcessRunner()) {
        self.processRunner = processRunner
        transfer = ArchiveTransfer(processRunner: processRunner)
    }

    func load(
        meetingID: UUID,
        revision: Int,
        configuration: ArchiveTransferConfiguration
    ) async throws -> SpeakerReviewResponse {
        let locateResult = try await runChecked(
            SpeakerReviewCommandBuilder.locate(meetingID: meetingID, configuration: configuration)
        )
        let located: LocatedSpeakerArchive
        do {
            located = try ModelCodec.decoder.decode(LocatedSpeakerArchive.self, from: locateResult.stdout)
            try located.validate(meetingID: meetingID, configuration: configuration)
        } catch let error as SpeakerReviewError {
            throw error
        } catch {
            throw SpeakerReviewError.invalidResponse("Could not read locate response: \(error.localizedDescription)")
        }

        let reviewResult = try await runChecked(
            SpeakerReviewCommandBuilder.review(
                archivePath: located.archivePath,
                revision: revision,
                configuration: configuration
            )
        )
        do {
            let response = try ModelCodec.decoder.decode(SpeakerReviewResponse.self, from: reviewResult.stdout)
            try response.validate(meetingID: meetingID, revision: revision)
            return response
        } catch let error as SpeakerReviewError {
            throw error
        } catch {
            throw SpeakerReviewError.invalidResponse("Could not read speaker review: \(error.localizedDescription)")
        }
    }

    func identify(
        meetingID: UUID,
        revision: Int,
        speakerID: String,
        name: String,
        configuration: ArchiveTransferConfiguration
    ) async throws -> SpeakerIdentificationResponse {
        let result = try await runChecked(
            SpeakerReviewCommandBuilder.identify(
                meetingID: meetingID,
                revision: revision,
                speakerID: speakerID,
                name: name,
                configuration: configuration
            )
        )
        let response: SpeakerIdentificationResponse
        do {
            response = try ModelCodec.decoder.decode(SpeakerIdentificationResponse.self, from: result.stdout)
        } catch {
            throw SpeakerReviewError.invalidResponse("Could not read speaker confirmation: \(error.localizedDescription)")
        }
        guard response.schemaVersion == 1,
              response.confirmed,
              response.meetingID == meetingID,
              response.manifestRevision == revision,
              response.speakerID == speakerID,
              response.name == name.trimmingCharacters(in: .whitespacesAndNewlines)
        else {
            throw SpeakerReviewError.invalidResponse("identify returned an unexpected confirmation")
        }
        return response
    }

    func fetchPlayback(
        meetingID: UUID,
        destination: URL,
        configuration: ArchiveTransferConfiguration
    ) async throws -> URL {
        try await transfer.fetch(
            relativePath: "playback/meeting.mp4",
            meetingID: meetingID,
            destination: destination,
            configuration: configuration
        )
    }

    private func runChecked(_ request: ArchiveProcessRequest) async throws -> ArchiveProcessResult {
        let result = try await processRunner.run(request)
        guard result.exitCode == 0 else {
            throw ArchiveTransferError.commandFailed(
                executable: request.executable.path,
                exitCode: result.exitCode,
                stderr: result.stderr
            )
        }
        return result
    }
}

@MainActor
final class SpeakerReviewModel: ObservableObject {
    @Published private(set) var response: SpeakerReviewResponse?
    @Published private(set) var drafts: [String: SpeakerReviewDraft] = [:]
    @Published private(set) var confirmedSpeakerIDs: Set<String> = []
    @Published private(set) var confirmingSpeakerIDs: Set<String> = []
    @Published private(set) var isLoading = false
    @Published private(set) var playbackStatus: String?
    @Published var failure: String?
    @Published private(set) var player: AVPlayer?

    let meetingID: UUID
    let revision: Int
    private let configuration: ArchiveTransferConfiguration
    private let client: any SpeakerReviewServing
    private let onReviewChanged: () -> Void
    private var playbackURL: URL?
    private var playbackTask: Task<Void, Never>?
    private var playbackFetchTask: Task<URL, Error>?
    private var playbackGeneration = 0
    @Published private(set) var isFetchingPlayback = false

    var remainingUnconfirmedCount: Int {
        guard let response else { return 0 }
        return response.speakers.lazy.filter { !self.confirmedSpeakerIDs.contains($0.speakerID) }.count
    }

    var canComplete: Bool {
        response != nil && !isLoading && confirmingSpeakerIDs.isEmpty && remainingUnconfirmedCount == 0
    }

    init(
        meetingID: UUID,
        revision: Int,
        configuration: ArchiveTransferConfiguration,
        client: any SpeakerReviewServing = SpeakerReviewClient(),
        onReviewChanged: @escaping () -> Void = {}
    ) {
        self.meetingID = meetingID
        self.revision = revision
        self.configuration = configuration
        self.client = client
        self.onReviewChanged = onReviewChanged
    }

    deinit { playbackTask?.cancel() }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        failure = nil
        defer { isLoading = false }
        do {
            let response = try await client.load(
                meetingID: meetingID,
                revision: revision,
                configuration: configuration
            )
            self.response = response
            drafts = SpeakerReviewDraft.make(speakers: response.speakers)
            confirmedSpeakerIDs = Set(response.speakers.compactMap { speaker in
                guard let name = speaker.name?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !name.isEmpty
                else { return nil }
                return speaker.speakerID
            })
        } catch {
            failure = error.localizedDescription
        }
    }

    func setName(_ name: String, for speakerID: String) {
        guard response?.speakers.contains(where: { $0.speakerID == speakerID }) == true else { return }
        drafts[speakerID] = SpeakerReviewDraft(name: name, isPredicted: false)
        confirmedSpeakerIDs.remove(speakerID)
    }

    @discardableResult
    func confirm(_ speakerID: String) async -> Bool {
        guard response?.speakers.contains(where: { $0.speakerID == speakerID }) == true,
              let draft = drafts[speakerID],
              confirmingSpeakerIDs.insert(speakerID).inserted
        else { return false }
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            failure = SpeakerReviewError.emptyName.description
            confirmingSpeakerIDs.remove(speakerID)
            return false
        }
        failure = nil
        defer { confirmingSpeakerIDs.remove(speakerID) }
        do {
            _ = try await client.identify(
                meetingID: meetingID,
                revision: revision,
                speakerID: speakerID,
                name: name,
                configuration: configuration
            )
            onReviewChanged()
            let currentName = drafts[speakerID]?.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard currentName == name else {
                // The remote confirmation succeeded, but the user typed a
                // newer draft while it was in flight. Keep that draft pending.
                return false
            }
            drafts[speakerID] = SpeakerReviewDraft(name: name, isPredicted: false)
            confirmedSpeakerIDs.insert(speakerID)
            return true
        } catch {
            failure = error.localizedDescription
            return false
        }
    }

    func play(_ excerpt: SpeakerReviewExcerpt, speakerID: String) async {
        guard excerpt.playbackPath != nil,
              let range = SpeakerPlaybackRange(start: excerpt.start, end: excerpt.end)
        else {
            playbackStatus = "This excerpt has text but no generated playback file."
            return
        }
        playbackGeneration &+= 1
        let generation = playbackGeneration
        playbackTask?.cancel()
        playbackTask = nil
        do {
            let url = try await localPlaybackURL()
            guard generation == playbackGeneration else { return }
            let player = player ?? AVPlayer(url: url)
            self.player = player
            player.pause()
            await player.seek(to: CMTime(seconds: range.start, preferredTimescale: 600))
            guard generation == playbackGeneration else { return }
            player.play()
            playbackStatus = "Playing \(speakerID) from \(formatTime(range.start)) to \(formatTime(range.end))"
            playbackTask = Task { [weak self, weak player] in
                try? await Task.sleep(for: .seconds(range.end - range.start))
                guard !Task.isCancelled, self?.playbackGeneration == generation else { return }
                player?.pause()
                self?.playbackStatus = nil
            }
        } catch {
            guard generation == playbackGeneration else { return }
            failure = error.localizedDescription
        }
    }

    func stopPlayback() {
        playbackGeneration &+= 1
        playbackTask?.cancel()
        playbackTask = nil
        playbackFetchTask?.cancel()
        player?.pause()
        player = nil
        playbackStatus = nil
    }

    private func localPlaybackURL() async throws -> URL {
        if let playbackURL { return playbackURL }
        if let playbackFetchTask { return try await playbackFetchTask.value }
        playbackStatus = "Fetching the archived playback…"
        isFetchingPlayback = true
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-archive-speaker-review", isDirectory: true)
            .appendingPathComponent(meetingID.uuidString.lowercased(), isDirectory: true)
        let destination = directory.appendingPathComponent("meeting.mp4")
        let task = Task { [client, configuration, meetingID] in
            try await client.fetchPlayback(
                meetingID: meetingID,
                destination: destination,
                configuration: configuration
            )
        }
        playbackFetchTask = task
        defer {
            playbackFetchTask = nil
            isFetchingPlayback = false
        }
        let result = try await task.value
        playbackURL = result
        return result
    }

    private func formatTime(_ seconds: Double) -> String {
        let rounded = max(0, Int(seconds.rounded(.down)))
        return String(format: "%d:%02d", rounded / 60, rounded % 60)
    }
}

@MainActor
struct SpeakerReviewView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: SpeakerReviewModel
    private let onComplete: () -> Void
    private let onLater: () -> Void

    init(
        meetingID: UUID,
        revision: Int,
        configuration: ArchiveTransferConfiguration,
        onComplete: @escaping () -> Void = {},
        onReviewChanged: @escaping () -> Void = {},
        onLater: @escaping () -> Void = {}
    ) {
        self.onComplete = onComplete
        self.onLater = onLater
        _model = StateObject(
            wrappedValue: SpeakerReviewModel(
                meetingID: meetingID,
                revision: revision,
                configuration: configuration,
                onReviewChanged: onReviewChanged
            )
        )
    }

    var body: some View {
        NavigationStack {
            Group {
                if model.isLoading && model.response == nil {
                    ProgressView("Loading speaker samples…")
                } else if let response = model.response {
                    reviewList(response)
                } else {
                    ContentUnavailableView(
                        "Speaker review unavailable",
                        systemImage: "person.wave.2",
                        description: Text(model.failure ?? "The archived speaker analysis could not be loaded.")
                    )
                }
            }
            .navigationTitle("Review speakers")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Later") {
                        model.stopPlayback()
                        onLater()
                        dismiss()
                    }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    if model.response == nil && !model.isLoading {
                        Button("Try again") { Task { await model.load() } }
                    }
                    Button("Complete") {
                        model.stopPlayback()
                        onComplete()
                        dismiss()
                    }
                    .disabled(!model.canComplete)
                }
            }
        }
        .frame(minWidth: 620, minHeight: 560)
        .task { if model.response == nil { await model.load() } }
        .onDisappear { model.stopPlayback() }
    }

    private func reviewList(_ response: SpeakerReviewResponse) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                Text("Listen to a sample, type the person’s name, then confirm it. Predicted names are suggestions until you confirm them.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                if let failure = model.failure {
                    Label(failure, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }

                if let player = model.player {
                    SpeakerPlayerView(player: player)
                        .frame(height: 180)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                if let status = model.playbackStatus {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }

                if response.speakers.isEmpty {
                    ContentUnavailableView(
                        "No speakers found",
                        systemImage: "person.slash",
                        description: Text("The archived transcript has no speaker tracks to review.")
                    )
                }

                ForEach(response.speakers) { speaker in
                    speakerCard(speaker, candidates: response.calendarCandidates)
                }
            }
            .padding(20)
        }
    }

    private func speakerCard(
        _ speaker: SpeakerReviewSpeaker,
        candidates: [SpeakerCalendarCandidate]
    ) -> some View {
        let draft = model.drafts[speaker.speakerID] ?? SpeakerReviewDraft(name: "", isPredicted: false)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(speaker.speakerID).font(.headline)
                if model.confirmedSpeakerIDs.contains(speaker.speakerID) {
                    Label("Confirmed", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
                Spacer()
                if speaker.embeddingAvailable {
                    Text("Voice sample available").font(.caption).foregroundStyle(.secondary)
                }
            }

            if speaker.excerpts.isEmpty {
                Text("No excerpt is available for this speaker.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(speaker.excerpts) { excerpt in
                    HStack(alignment: .top, spacing: 10) {
                        Button {
                            Task { await model.play(excerpt, speakerID: speaker.speakerID) }
                        } label: {
                            Image(systemName: "play.circle.fill").font(.title2)
                        }
                        .buttonStyle(.plain)
                        .disabled(excerpt.playbackPath == nil || model.isFetchingPlayback)
                        .help(excerpt.playbackPath == nil ? "Playback has not been generated" : "Play this excerpt")

                        VStack(alignment: .leading, spacing: 3) {
                            Text(excerpt.text).textSelection(.enabled)
                            Text("\(formatTime(excerpt.start))–\(formatTime(excerpt.end)) · \(excerpt.channelOrigin)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            TextField(
                "Speaker name",
                text: Binding(
                    get: { model.drafts[speaker.speakerID]?.name ?? "" },
                    set: { model.setName($0, for: speaker.speakerID) }
                )
            )
            if draft.isPredicted {
                Text(predictionLabel(speaker))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !candidates.isEmpty {
                Menu("Choose a calendar attendee") {
                    ForEach(candidates) { candidate in
                        Button(candidateLabel(candidate)) {
                            model.setName(candidate.name, for: speaker.speakerID)
                        }
                    }
                }
            }

            HStack {
                Spacer()
                Button("Confirm") { Task { await model.confirm(speaker.speakerID) } }
                    .disabled(
                        draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || model.confirmingSpeakerIDs.contains(speaker.speakerID)
                            || model.confirmedSpeakerIDs.contains(speaker.speakerID)
                    )
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    private func predictionLabel(_ speaker: SpeakerReviewSpeaker) -> String {
        if let score = speaker.suggestionScore, score.isFinite {
            return "Predicted name, \(score.formatted(.percent.precision(.fractionLength(0)))) confidence. Confirm or replace it."
        }
        return "Predicted name. Confirm or replace it."
    }

    private func candidateLabel(_ candidate: SpeakerCalendarCandidate) -> String {
        guard let email = candidate.email, !email.isEmpty else { return candidate.name }
        return "\(candidate.name) (\(email))"
    }

    private func formatTime(_ seconds: Double) -> String {
        let rounded = max(0, Int(seconds.rounded(.down)))
        return String(format: "%d:%02d", rounded / 60, rounded % 60)
    }
}
