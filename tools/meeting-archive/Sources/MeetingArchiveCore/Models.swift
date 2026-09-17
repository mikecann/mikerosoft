import Foundation

public enum MeetingApplicationKind: String, Codable, Sendable {
    case googleMeet = "google_meet"
    case zoom
    case teams
    case slack
    case recordIt = "record_it"
    case cameraPreview = "camera_preview"
    case other

    public var isSupportedMeetingApplication: Bool {
        switch self {
        case .googleMeet, .zoom, .teams, .slack: true
        case .recordIt, .cameraPreview, .other: false
        }
    }
}

public struct SourceApplicationDescriptor: Codable, Equatable, Sendable {
    public var bundleIdentifier: String
    public var displayName: String
    public var kind: MeetingApplicationKind

    public init(bundleIdentifier: String, displayName: String, kind: MeetingApplicationKind) {
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
        self.kind = kind
    }
}

public enum MeetingSurfaceKind: String, Codable, Sendable {
    case meeting
    case cameraPreview = "camera_preview"
    case unknown
}

public struct MeetingSurfaceDescriptor: Codable, Equatable, Sendable {
    public var id: String
    public var title: String?
    public var kind: MeetingSurfaceKind

    public init(id: String, title: String?, kind: MeetingSurfaceKind) {
        self.id = id
        self.title = title
        self.kind = kind
    }
}

public enum MeetingAttribution: String, Codable, Sendable {
    case positive
    case unknown
}

public struct MeetingSessionDescriptor: Codable, Equatable, Sendable {
    public var id: String
    public var sourceApplication: SourceApplicationDescriptor
    public var surface: MeetingSurfaceDescriptor
    public var attribution: MeetingAttribution

    public init(
        id: String,
        sourceApplication: SourceApplicationDescriptor,
        surface: MeetingSurfaceDescriptor,
        attribution: MeetingAttribution
    ) {
        self.id = id
        self.sourceApplication = sourceApplication
        self.surface = surface
        self.attribution = attribution
    }

    public var isEligibleForCapture: Bool {
        !id.isEmpty
            && attribution == .positive
            && sourceApplication.kind.isSupportedMeetingApplication
            && surface.kind == .meeting
    }
}

public enum SessionSuppressionReason: String, Codable, Sendable {
    case skipped
    case paused
    case interrupted
}

public enum ActiveSessionPhase: Codable, Equatable, Sendable {
    case startRequested
    case recording
    case suppressed(SessionSuppressionReason)

    private enum CodingKeys: String, CodingKey { case status, reason }
    private enum Status: String, Codable { case startRequested = "start_requested", recording, suppressed }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Status.self, forKey: .status) {
        case .startRequested: self = .startRequested
        case .recording: self = .recording
        case .suppressed: self = .suppressed(try container.decode(SessionSuppressionReason.self, forKey: .reason))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .startRequested:
            try container.encode(Status.startRequested, forKey: .status)
        case .recording:
            try container.encode(Status.recording, forKey: .status)
        case .suppressed(let reason):
            try container.encode(Status.suppressed, forKey: .status)
            try container.encode(reason, forKey: .reason)
        }
    }
}

public struct ActiveMeetingSession: Codable, Equatable, Sendable {
    public var descriptor: MeetingSessionDescriptor
    public var phase: ActiveSessionPhase
    public var firstObservedAt: Date
    public var meetingID: UUID?

    public init(
        descriptor: MeetingSessionDescriptor,
        phase: ActiveSessionPhase,
        firstObservedAt: Date,
        meetingID: UUID?
    ) {
        self.descriptor = descriptor
        self.phase = phase
        self.firstObservedAt = firstObservedAt
        self.meetingID = meetingID
    }
}

public struct RecorderState: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var isPaused: Bool
    public var currentSession: ActiveMeetingSession?
    public var completedSessionIDs: [String]

    public init(
        schemaVersion: Int = 1,
        isPaused: Bool = false,
        currentSession: ActiveMeetingSession? = nil,
        completedSessionIDs: [String] = []
    ) {
        self.schemaVersion = schemaVersion
        self.isPaused = isPaused
        self.currentSession = currentSession
        self.completedSessionIDs = completedSessionIDs
    }

    /// A persisted writer cannot still be alive after this process starts.
    /// Keep the session suppressed until its detector reports a real off edge,
    /// rather than starting a second recording because the app remains open.
    public func restoredAfterProcessRestart() -> RecorderState {
        guard var currentSession else { return self }
        switch currentSession.phase {
        case .startRequested, .recording:
            currentSession.phase = .suppressed(.interrupted)
            var copy = self
            copy.currentSession = currentSession
            return copy
        case .suppressed:
            return self
        }
    }
}

public struct VideoSourceDescriptor: Codable, Equatable, Sendable {
    public var surfaceID: String
    public var codec: String
    public var width: Int
    public var height: Int

    public init(surfaceID: String, codec: String, width: Int, height: Int) {
        self.surfaceID = surfaceID
        self.codec = codec
        self.width = width
        self.height = height
    }
}

public struct MicrophoneSourceDescriptor: Codable, Equatable, Sendable {
    public var deviceUID: String
    public var displayName: String
    public var sampleRate: Int
    public var channels: Int

    public init(deviceUID: String, displayName: String, sampleRate: Int, channels: Int) {
        self.deviceUID = deviceUID
        self.displayName = displayName
        self.sampleRate = sampleRate
        self.channels = channels
    }
}

public struct IncomingAudioSourceDescriptor: Codable, Equatable, Sendable {
    public var sourceApplicationBundleIdentifier: String
    public var sampleRate: Int
    public var channels: Int

    public init(sourceApplicationBundleIdentifier: String, sampleRate: Int, channels: Int) {
        self.sourceApplicationBundleIdentifier = sourceApplicationBundleIdentifier
        self.sampleRate = sampleRate
        self.channels = channels
    }
}

public enum AcceptanceTrigger: String, Codable, Sendable {
    case keepButton = "keep_button"
    case promptClosed = "prompt_closed"
    case deadline
    case restartRecovery = "restart_recovery"
}

public enum AcceptanceState: Codable, Equatable, Sendable {
    case pending(deadline: Date)
    case accepted(at: Date, trigger: AcceptanceTrigger)
    case discarded(at: Date)

    private enum CodingKeys: String, CodingKey { case status, deadline, resolvedAt = "resolved_at", trigger }
    private enum Status: String, Codable { case pending, accepted, discarded }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Status.self, forKey: .status) {
        case .pending:
            self = .pending(deadline: try container.decode(Date.self, forKey: .deadline))
        case .accepted:
            self = .accepted(
                at: try container.decode(Date.self, forKey: .resolvedAt),
                trigger: try container.decode(AcceptanceTrigger.self, forKey: .trigger)
            )
        case .discarded:
            self = .discarded(at: try container.decode(Date.self, forKey: .resolvedAt))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .pending(let deadline):
            try container.encode(Status.pending, forKey: .status)
            try container.encode(deadline, forKey: .deadline)
        case .accepted(let at, let trigger):
            try container.encode(Status.accepted, forKey: .status)
            try container.encode(at, forKey: .resolvedAt)
            try container.encode(trigger, forKey: .trigger)
        case .discarded(let at):
            try container.encode(Status.discarded, forKey: .status)
            try container.encode(at, forKey: .resolvedAt)
        }
    }

    public var isPending: Bool {
        if case .pending = self { return true }
        return false
    }
}

public enum AcceptanceResolution: Equatable, Sendable {
    case accept(trigger: AcceptanceTrigger)
    case discard
}

public struct MeetingRecord: Codable, Equatable, Sendable {
    public static let acceptanceDelay: TimeInterval = 20

    public var schemaVersion: Int
    public var id: UUID
    public var title: String
    public var sourceApplication: SourceApplicationDescriptor
    public var startedAt: Date
    public var endedAt: Date
    public var timezoneIdentifier: String
    public var video: VideoSourceDescriptor
    public var microphone: MicrophoneSourceDescriptor
    public var incomingAudio: IncomingAudioSourceDescriptor
    public var acceptance: AcceptanceState
    public var metadataRevision: Int
    public var updatedAt: Date

    public init(
        schemaVersion: Int = 1,
        id: UUID = UUID(),
        title: String,
        sourceApplication: SourceApplicationDescriptor,
        startedAt: Date,
        endedAt: Date,
        timezoneIdentifier: String,
        video: VideoSourceDescriptor,
        microphone: MicrophoneSourceDescriptor,
        incomingAudio: IncomingAudioSourceDescriptor,
        finalizedAt: Date
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.title = title
        self.sourceApplication = sourceApplication
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.timezoneIdentifier = timezoneIdentifier
        self.video = video
        self.microphone = microphone
        self.incomingAudio = incomingAudio
        self.acceptance = .pending(deadline: finalizedAt.addingTimeInterval(Self.acceptanceDelay))
        self.metadataRevision = 1
        self.updatedAt = finalizedAt
    }

    public func resolvingDeadline(at date: Date) -> MeetingRecord? {
        guard case .pending(let deadline) = acceptance, date >= deadline else { return nil }
        return resolvingAcceptance(.accept(trigger: .deadline), at: date)
    }

    public func resolvingAcceptance(_ resolution: AcceptanceResolution, at date: Date) -> MeetingRecord {
        guard acceptance.isPending else { return self }
        var copy = self
        switch resolution {
        case .accept(let trigger): copy.acceptance = .accepted(at: date, trigger: trigger)
        case .discard: copy.acceptance = .discarded(at: date)
        }
        copy.updatedAt = date
        return copy
    }

    public func updatingTitle(_ title: String, at date: Date) -> MeetingRecord {
        var copy = self
        copy.title = title
        copy.metadataRevision += 1
        copy.updatedAt = date
        return copy
    }
}

public enum ArchiveJobStatus: String, Codable, Sendable {
    case queued
    case leased
    case retryScheduled = "retry_scheduled"
    case succeeded
    case failed
}

public struct ArchiveJob: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var id: UUID
    public var meetingID: UUID
    public var manifestRevision: Int
    public var createdAt: Date
    public var availableAt: Date
    public var leaseUntil: Date?
    public var attemptCount: Int
    public var status: ArchiveJobStatus
    public var lastError: String?
    public var acknowledgement: ArchiveAcknowledgement?

    public init(
        schemaVersion: Int = 1,
        id: UUID = UUID(),
        meetingID: UUID,
        manifestRevision: Int,
        createdAt: Date,
        availableAt: Date? = nil,
        leaseUntil: Date? = nil,
        attemptCount: Int = 0,
        status: ArchiveJobStatus = .queued,
        lastError: String? = nil,
        acknowledgement: ArchiveAcknowledgement? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.meetingID = meetingID
        self.manifestRevision = manifestRevision
        self.createdAt = createdAt
        self.availableAt = availableAt ?? createdAt
        self.leaseUntil = leaseUntil
        self.attemptCount = attemptCount
        self.status = status
        self.lastError = lastError
        self.acknowledgement = acknowledgement
    }
}
