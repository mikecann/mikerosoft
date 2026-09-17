import Foundation

enum WorkerProcessingState: String, Codable, Equatable, Sendable {
    case ready
    case leased
    case retryWait = "retry_wait"
    case succeeded
    case permanentFailure = "permanent_failure"
}

enum WorkerPublicationState: String, Codable, Equatable, Sendable {
    case ready
    case publishing
    case retryWait = "retry_wait"
    case succeeded
}

enum WorkerMeetingPhase: String, Equatable, Sendable {
    case archived
    case processing
    case published
    case needsAttention
}

enum WorkerSpeakerReviewState: String, Equatable, Sendable {
    case waitingForProcessing
    case available
}

enum WorkerRetryStage: String, Equatable, Sendable {
    case processing
    case publication
}

struct WorkerMeetingStatus: Equatable, Sendable {
    var meetingID: UUID
    var phase: WorkerMeetingPhase
    var processingState: WorkerProcessingState?
    var publicationState: WorkerPublicationState?
    var speakerReview: WorkerSpeakerReviewState
    var retryStage: WorkerRetryStage?
    var lastError: String?

    var detail: String {
        switch phase {
        case .archived:
            return "Archived on Bruce; processing status is not available"
        case .needsAttention:
            let stage = retryStage == .publication ? "Notion publication" : "Meeting processing"
            return lastError.map { "\(stage) needs attention: \($0)" }
                ?? "\(stage) needs attention"
        case .published:
            return "Published to Notion • speaker review available"
        case .processing:
            if processingState != .succeeded {
                return processingState == .leased
                    ? "Diarization in progress"
                    : "Archived • processing queued"
            }
            switch publicationState {
            case .publishing:
                return "Speaker review available • publishing to Notion"
            case .ready, nil:
                return "Speaker review available • Notion queued"
            case .retryWait:
                return "Speaker review available • Notion waiting to retry"
            case .succeeded:
                return "Published to Notion • speaker review available"
            }
        }
    }
}

struct WorkerStatusResponse: Codable, Equatable, Sendable {
    var schemaVersion: Int
    var counts: [String: Int]
    var jobs: [WorkerProcessingJob]
    var publication: WorkerPublicationStatus

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case counts, jobs, publication
    }

    func statuses(for meetingIDs: some Sequence<UUID>) throws -> [UUID: WorkerMeetingStatus] {
        guard schemaVersion == 1 else {
            throw WorkerStatusError.invalidResponse("Unsupported worker status schema \(schemaVersion)")
        }
        let requested = Set(meetingIDs)
        guard Set(jobs.map(\.id)).count == jobs.count else {
            throw WorkerStatusError.invalidResponse("Worker status returned duplicate processing job IDs")
        }
        guard Set(publication.jobs.map(\.processingJobID)).count == publication.jobs.count else {
            throw WorkerStatusError.invalidResponse("Worker status returned duplicate publication jobs")
        }
        let processingIDs = Set(jobs.map(\.id))
        guard publication.jobs.allSatisfy({ processingIDs.contains($0.processingJobID) }) else {
            throw WorkerStatusError.invalidResponse("Publication status did not match a processing job")
        }
        guard jobs.allSatisfy({ $0.manifestRevision >= 1 }) else {
            throw WorkerStatusError.invalidResponse("Worker status returned an invalid manifest revision")
        }

        let jobsByMeeting = Dictionary(grouping: jobs, by: \.meetingID).mapValues { candidates in
            candidates.max {
                ($0.manifestRevision, $0.id) < ($1.manifestRevision, $1.id)
            }!
        }
        let publicationByJob = Dictionary(
            uniqueKeysWithValues: publication.jobs.map { ($0.processingJobID, $0) }
        )
        return Dictionary(uniqueKeysWithValues: requested.map { meetingID in
            guard let job = jobsByMeeting[meetingID] else {
                return (
                    meetingID,
                    WorkerMeetingStatus(
                        meetingID: meetingID,
                        phase: .archived,
                        processingState: nil,
                        publicationState: nil,
                        speakerReview: .waitingForProcessing,
                        retryStage: nil,
                        lastError: nil
                    )
                )
            }
            let publicationJob = publicationByJob[job.id]
            return (meetingID, Self.makeStatus(job: job, publication: publicationJob))
        })
    }

    private static func makeStatus(
        job: WorkerProcessingJob,
        publication: WorkerPublicationJob?
    ) -> WorkerMeetingStatus {
        if job.state == .permanentFailure || job.state == .retryWait {
            return WorkerMeetingStatus(
                meetingID: job.meetingID,
                phase: .needsAttention,
                processingState: job.state,
                publicationState: publication?.state,
                speakerReview: .waitingForProcessing,
                retryStage: .processing,
                lastError: job.lastError
            )
        }
        guard job.state == .succeeded else {
            return WorkerMeetingStatus(
                meetingID: job.meetingID,
                phase: .processing,
                processingState: job.state,
                publicationState: publication?.state,
                speakerReview: .waitingForProcessing,
                retryStage: nil,
                lastError: nil
            )
        }
        if publication?.state == .retryWait {
            return WorkerMeetingStatus(
                meetingID: job.meetingID,
                phase: .needsAttention,
                processingState: .succeeded,
                publicationState: .retryWait,
                speakerReview: .available,
                retryStage: .publication,
                lastError: publication?.lastError
            )
        }
        return WorkerMeetingStatus(
            meetingID: job.meetingID,
            phase: publication?.state == .succeeded ? .published : .processing,
            processingState: .succeeded,
            publicationState: publication?.state,
            speakerReview: .available,
            retryStage: nil,
            lastError: nil
        )
    }
}

struct WorkerProcessingJob: Codable, Equatable, Sendable {
    var id: Int
    var meetingID: UUID
    var manifestRevision: Int
    var manifestSHA256: String
    var archivePath: String
    var state: WorkerProcessingState
    var attempts: Int
    var availableAt: Double
    var leaseOwner: String?
    var leaseExpiresAt: Double?
    var lastError: String?

    enum CodingKeys: String, CodingKey {
        case id
        case meetingID = "meeting_id"
        case manifestRevision = "manifest_revision"
        case manifestSHA256 = "manifest_sha256"
        case archivePath = "archive_path"
        case state, attempts
        case availableAt = "available_at"
        case leaseOwner = "lease_owner"
        case leaseExpiresAt = "lease_expires_at"
        case lastError = "last_error"
    }
}

struct WorkerPublicationStatus: Codable, Equatable, Sendable {
    var counts: [String: Int]
    var phase: String
    var lastError: String?
    var jobs: [WorkerPublicationJob]

    enum CodingKeys: String, CodingKey {
        case counts, phase, jobs
        case lastError = "last_error"
    }
}

struct WorkerPublicationJob: Codable, Equatable, Sendable {
    var processingJobID: Int
    var archivePath: String
    var state: WorkerPublicationState
    var attempts: Int
    var availableAt: Double
    var lastError: String?
    var leaseOwner: String?
    var leaseExpiresAt: Double?
    var refreshRequested: Int

    enum CodingKeys: String, CodingKey {
        case processingJobID = "processing_job_id"
        case archivePath = "archive_path"
        case state, attempts
        case availableAt = "available_at"
        case lastError = "last_error"
        case leaseOwner = "lease_owner"
        case leaseExpiresAt = "lease_expires_at"
        case refreshRequested = "refresh_requested"
    }
}

struct WorkerRetryResponse: Codable, Equatable, Sendable {
    var schemaVersion: Int
    var meetingID: UUID
    var retried: Bool
    var processing: WorkerRetryProcessing
    var publication: WorkerRetryPublication?

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case meetingID = "meeting_id"
        case retried, processing, publication
    }

    func validate(meetingID expectedMeetingID: UUID) throws {
        guard schemaVersion == 1, meetingID == expectedMeetingID else {
            throw WorkerStatusError.invalidResponse("Retry returned the wrong meeting or schema")
        }
    }
}

struct WorkerRetryProcessing: Codable, Equatable, Sendable {
    var jobID: Int
    var state: WorkerProcessingState
    var retried: Bool

    enum CodingKeys: String, CodingKey {
        case jobID = "job_id"
        case state, retried
    }
}

struct WorkerRetryPublication: Codable, Equatable, Sendable {
    var processingJobID: Int
    var state: WorkerPublicationState
    var retried: Bool

    enum CodingKeys: String, CodingKey {
        case processingJobID = "processing_job_id"
        case state, retried
    }
}

enum WorkerStatusError: Error, Equatable, LocalizedError {
    case tooManyMeetings
    case invalidResponse(String)
    case commandFailed(exitCode: Int32, stderr: String)

    var errorDescription: String? {
        switch self {
        case .tooManyMeetings:
            return "Worker status can refresh at most 100 meetings at once."
        case .invalidResponse(let message):
            return message
        case .commandFailed(let exitCode, let stderr):
            return "Bruce worker command failed with \(exitCode): \(stderr)"
        }
    }
}

enum WorkerStatusCommandBuilder {
    static func status(
        meetingIDs: [UUID],
        configuration: ArchiveTransferConfiguration
    ) throws -> ArchiveProcessRequest {
        try configuration.validate()
        guard meetingIDs.count <= 100 else { throw WorkerStatusError.tooManyMeetings }
        var workerArguments = workerPrefix(configuration) + [
            "status", "--db", configuration.workerDatabase,
        ]
        for meetingID in meetingIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
            workerArguments += ["--meeting-id", meetingID.uuidString.lowercased()]
        }
        return remoteRequest(
            arguments: workerArguments,
            timeout: configuration.commandTimeout,
            configuration: configuration
        )
    }

    static func retry(
        meetingID: UUID,
        configuration: ArchiveTransferConfiguration
    ) throws -> ArchiveProcessRequest {
        try configuration.validate()
        return remoteRequest(
            arguments: workerPrefix(configuration) + [
                "retry",
                "--meeting-id", meetingID.uuidString.lowercased(),
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

actor WorkerStatusClient {
    private let processRunner: any ArchiveProcessRunning
    private let cacheDuration: TimeInterval
    private var cache: [UUID: WorkerMeetingStatus] = [:]
    private var cacheDate: Date?
    private var cacheConfiguration: ArchiveTransferConfiguration?
    private var remoteOperationActive = false
    private var remoteOperationWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        processRunner: any ArchiveProcessRunning = FoundationArchiveProcessRunner(),
        cacheDuration: TimeInterval = 30
    ) {
        self.processRunner = processRunner
        self.cacheDuration = cacheDuration
    }

    func fetch(
        meetingIDs: [UUID],
        configuration: ArchiveTransferConfiguration,
        force: Bool = false
    ) async throws -> [UUID: WorkerMeetingStatus] {
        let uniqueIDs = Array(Set(meetingIDs))
        guard !uniqueIDs.isEmpty else { return [:] }
        guard uniqueIDs.count <= 100 else { throw WorkerStatusError.tooManyMeetings }
        if !force, !remoteOperationActive,
           cacheConfiguration == configuration,
           let cacheDate,
           Date().timeIntervalSince(cacheDate) < cacheDuration,
           uniqueIDs.allSatisfy({ cache[$0] != nil }) {
            return Dictionary(uniqueKeysWithValues: uniqueIDs.compactMap { id in
                cache[id].map { (id, $0) }
            })
        }

        await beginRemoteOperation()
        defer { endRemoteOperation() }
        // Another fetch may have populated the cache while this request was
        // waiting behind an older status or retry operation.
        if !force,
           cacheConfiguration == configuration,
           let cacheDate,
           Date().timeIntervalSince(cacheDate) < cacheDuration,
           uniqueIDs.allSatisfy({ cache[$0] != nil }) {
            return Dictionary(uniqueKeysWithValues: uniqueIDs.compactMap { id in
                cache[id].map { (id, $0) }
            })
        }

        let request = try WorkerStatusCommandBuilder.status(
            meetingIDs: uniqueIDs,
            configuration: configuration
        )
        let result = try await processRunner.run(request)
        guard result.exitCode == 0 else {
            throw WorkerStatusError.commandFailed(exitCode: result.exitCode, stderr: result.stderr)
        }
        let response: WorkerStatusResponse
        do {
            response = try JSONDecoder().decode(WorkerStatusResponse.self, from: result.stdout)
        } catch {
            throw WorkerStatusError.invalidResponse("Bruce returned invalid worker status: \(error.localizedDescription)")
        }
        let statuses = try response.statuses(for: uniqueIDs)
        cache = statuses
        cacheDate = Date()
        cacheConfiguration = configuration
        return statuses
    }

    func retry(
        meetingID: UUID,
        configuration: ArchiveTransferConfiguration
    ) async throws -> WorkerRetryResponse {
        await beginRemoteOperation()
        defer { endRemoteOperation() }
        let request = try WorkerStatusCommandBuilder.retry(
            meetingID: meetingID,
            configuration: configuration
        )
        let result = try await processRunner.run(request)
        guard result.exitCode == 0 else {
            throw WorkerStatusError.commandFailed(exitCode: result.exitCode, stderr: result.stderr)
        }
        let response: WorkerRetryResponse
        do {
            response = try JSONDecoder().decode(WorkerRetryResponse.self, from: result.stdout)
        } catch {
            throw WorkerStatusError.invalidResponse("Bruce returned an invalid retry response: \(error.localizedDescription)")
        }
        try response.validate(meetingID: meetingID)
        cache.removeValue(forKey: meetingID)
        return response
    }

    private func beginRemoteOperation() async {
        if !remoteOperationActive {
            remoteOperationActive = true
            return
        }
        await withCheckedContinuation { continuation in
            remoteOperationWaiters.append(continuation)
        }
    }

    private func endRemoteOperation() {
        guard !remoteOperationWaiters.isEmpty else {
            remoteOperationActive = false
            return
        }
        remoteOperationWaiters.removeFirst().resume()
    }
}
