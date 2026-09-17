import CryptoKit
import Foundation

public enum ManifestFileKind: String, Codable, Sendable {
    case metadata
    case video
    case microphoneAudio = "microphone_audio"
    case incomingAudio = "incoming_audio"
}

public struct ManifestFile: Codable, Equatable, Sendable {
    public var path: String
    public var sizeBytes: Int64
    public var sha256: String
    public var kind: ManifestFileKind

    public init(path: String, sizeBytes: Int64, sha256: String, kind: ManifestFileKind) {
        self.path = path
        self.sizeBytes = sizeBytes
        self.sha256 = sha256.lowercased()
        self.kind = kind
    }

    enum CodingKeys: String, CodingKey {
        case path
        case sizeBytes = "size_bytes"
        case sha256
        case kind
    }
}

public enum ContractValidationError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidSchemaVersion(Int)
    case invalidRevision(Int)
    case missingMetadata
    case duplicatePath(String)
    case unsafePath(String)
    case invalidSize(String)
    case invalidSHA256(String)
    case invalidTimeRange
    case invalidDuration
    case emptyTimezone
    case emptySourceApplication
    case cleanupNotAllowed

    public var description: String {
        switch self {
        case .invalidSchemaVersion(let version): "Unsupported schema version: \(version)"
        case .invalidRevision(let revision): "Revision must be at least one: \(revision)"
        case .missingMetadata: "metadata.json must be present in the file manifest"
        case .duplicatePath(let path): "Duplicate manifest path: \(path)"
        case .unsafePath(let path): "Manifest path is not bundle-relative: \(path)"
        case .invalidSize(let path): "Manifest file has a negative size: \(path)"
        case .invalidSHA256(let path): "Manifest file has an invalid SHA-256: \(path)"
        case .invalidTimeRange: "Meeting end must not precede its start"
        case .invalidDuration: "Meeting duration must be non-negative"
        case .emptyTimezone: "Meeting timezone must not be empty"
        case .emptySourceApplication: "Meeting source app must not be empty"
        case .cleanupNotAllowed: "Archive acknowledgement did not authorize local cleanup"
        }
    }
}

public struct TransferManifest: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var meetingID: UUID
    public var revision: Int
    public var files: [ManifestFile]

    public init(schemaVersion: Int = 1, meetingID: UUID, revision: Int, files: [ManifestFile]) {
        self.schemaVersion = schemaVersion
        self.meetingID = meetingID
        self.revision = revision
        self.files = files
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case meetingID = "meeting_id"
        case revision
        case files
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        let meetingIDString = try container.decode(String.self, forKey: .meetingID)
        guard let meetingID = UUID(uuidString: meetingIDString) else {
            throw DecodingError.dataCorruptedError(forKey: .meetingID, in: container, debugDescription: "meeting_id must be a UUID")
        }
        self.meetingID = meetingID
        revision = try container.decode(Int.self, forKey: .revision)
        files = try container.decode([ManifestFile].self, forKey: .files)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(meetingID.canonicalString, forKey: .meetingID)
        try container.encode(revision, forKey: .revision)
        try container.encode(files, forKey: .files)
    }

    public func validate() throws {
        guard schemaVersion == 1 else { throw ContractValidationError.invalidSchemaVersion(schemaVersion) }
        guard revision >= 1 else { throw ContractValidationError.invalidRevision(revision) }

        var paths = Set<String>()
        var hasMetadata = false
        for file in files {
            guard isSafeRelativePath(file.path) else { throw ContractValidationError.unsafePath(file.path) }
            guard paths.insert(file.path).inserted else { throw ContractValidationError.duplicatePath(file.path) }
            guard file.sizeBytes >= 0 else { throw ContractValidationError.invalidSize(file.path) }
            guard file.sha256.count == 64,
                  file.sha256.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789abcdef").contains($0) })
            else { throw ContractValidationError.invalidSHA256(file.path) }
            if file.path == "metadata.json" && file.kind == .metadata { hasMetadata = true }
        }
        guard hasMetadata else { throw ContractValidationError.missingMetadata }
    }

    public func canonicalData() throws -> Data {
        var canonical = self
        canonical.files.sort { $0.path < $1.path }
        return try ModelCodec.encoder.encode(canonical)
    }

    /// The worker hashes these exact bytes. The digest is not encoded back into
    /// the manifest because doing so would change the bytes being acknowledged.
    public func sha256Hex() -> String {
        let digest = SHA256.hash(data: try! canonicalData())
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("~"), !path.contains("\\") else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
}

public struct WorkerMeetingMetadata: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var meetingID: UUID
    public var manifestRevision: Int
    public var startedAt: Date
    public var endedAt: Date
    public var durationSeconds: TimeInterval
    public var timezone: String
    public var sourceApp: String

    public init(
        schemaVersion: Int = 1,
        meetingID: UUID,
        manifestRevision: Int,
        startedAt: Date,
        endedAt: Date,
        durationSeconds: TimeInterval,
        timezone: String,
        sourceApp: String
    ) {
        self.schemaVersion = schemaVersion
        self.meetingID = meetingID
        self.manifestRevision = manifestRevision
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.durationSeconds = durationSeconds
        self.timezone = timezone
        self.sourceApp = sourceApp
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case meetingID = "meeting_id"
        case manifestRevision = "manifest_revision"
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case durationSeconds = "duration_seconds"
        case timezone
        case sourceApp = "source_app"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        let id = try container.decode(String.self, forKey: .meetingID)
        guard let parsedID = UUID(uuidString: id) else {
            throw DecodingError.dataCorruptedError(forKey: .meetingID, in: container, debugDescription: "meeting_id must be a UUID")
        }
        meetingID = parsedID
        manifestRevision = try container.decode(Int.self, forKey: .manifestRevision)
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        endedAt = try container.decode(Date.self, forKey: .endedAt)
        durationSeconds = try container.decode(TimeInterval.self, forKey: .durationSeconds)
        timezone = try container.decode(String.self, forKey: .timezone)
        sourceApp = try container.decode(String.self, forKey: .sourceApp)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(meetingID.canonicalString, forKey: .meetingID)
        try container.encode(manifestRevision, forKey: .manifestRevision)
        try container.encode(startedAt, forKey: .startedAt)
        try container.encode(endedAt, forKey: .endedAt)
        try container.encode(durationSeconds, forKey: .durationSeconds)
        try container.encode(timezone, forKey: .timezone)
        try container.encode(sourceApp, forKey: .sourceApp)
    }

    public func validate() throws {
        guard schemaVersion == 1 else { throw ContractValidationError.invalidSchemaVersion(schemaVersion) }
        guard manifestRevision >= 1 else { throw ContractValidationError.invalidRevision(manifestRevision) }
        guard endedAt >= startedAt else { throw ContractValidationError.invalidTimeRange }
        guard durationSeconds >= 0 else { throw ContractValidationError.invalidDuration }
        guard !timezone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ContractValidationError.emptyTimezone }
        guard !sourceApp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ContractValidationError.emptySourceApplication }
    }

    public func validate(against manifest: TransferManifest) throws {
        try validate()
        guard meetingID == manifest.meetingID, manifestRevision == manifest.revision else {
            throw ContractValidationError.invalidRevision(manifestRevision)
        }
    }

    public func canonicalData() throws -> Data {
        try ModelCodec.encoder.encode(self)
    }
}

public struct ArchiveAcknowledgement: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var meetingID: UUID
    public var manifestRevision: Int
    public var manifestSHA256: String
    public var archivePath: String
    public var acceptedAt: Date
    public var verifiedFiles: [ManifestFile]
    public var queueJobID: String
    public var cleanupAllowed: Bool

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case meetingID = "meeting_id"
        case manifestRevision = "manifest_revision"
        case manifestSHA256 = "manifest_sha256"
        case archivePath = "archive_path"
        case acceptedAt = "accepted_at"
        case verifiedFiles = "verified_files"
        case queueJobID = "queue_job_id"
        case cleanupAllowed = "cleanup_allowed"
    }

    public init(
        schemaVersion: Int = 1,
        meetingID: UUID,
        manifestRevision: Int,
        manifestSHA256: String,
        archivePath: String,
        acceptedAt: Date,
        verifiedFiles: [ManifestFile],
        queueJobID: String,
        cleanupAllowed: Bool
    ) {
        self.schemaVersion = schemaVersion
        self.meetingID = meetingID
        self.manifestRevision = manifestRevision
        self.manifestSHA256 = manifestSHA256.lowercased()
        self.archivePath = archivePath
        self.acceptedAt = acceptedAt
        self.verifiedFiles = verifiedFiles
        self.queueJobID = queueJobID
        self.cleanupAllowed = cleanupAllowed
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        let rawID = try container.decode(String.self, forKey: .meetingID)
        guard let parsedID = UUID(uuidString: rawID) else {
            throw DecodingError.dataCorruptedError(forKey: .meetingID, in: container, debugDescription: "meeting_id must be a UUID")
        }
        meetingID = parsedID
        manifestRevision = try container.decode(Int.self, forKey: .manifestRevision)
        manifestSHA256 = try container.decode(String.self, forKey: .manifestSHA256)
        archivePath = try container.decode(String.self, forKey: .archivePath)
        acceptedAt = try container.decode(Date.self, forKey: .acceptedAt)
        verifiedFiles = try container.decode([ManifestFile].self, forKey: .verifiedFiles)
        queueJobID = try container.decode(String.self, forKey: .queueJobID)
        cleanupAllowed = try container.decode(Bool.self, forKey: .cleanupAllowed)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(meetingID.canonicalString, forKey: .meetingID)
        try container.encode(manifestRevision, forKey: .manifestRevision)
        try container.encode(manifestSHA256, forKey: .manifestSHA256)
        try container.encode(archivePath, forKey: .archivePath)
        try container.encode(acceptedAt, forKey: .acceptedAt)
        try container.encode(verifiedFiles, forKey: .verifiedFiles)
        try container.encode(queueJobID, forKey: .queueJobID)
        try container.encode(cleanupAllowed, forKey: .cleanupAllowed)
    }

    public func validate(against manifest: TransferManifest) throws {
        try manifest.validate()
        guard schemaVersion == 1 else { throw ContractValidationError.invalidSchemaVersion(schemaVersion) }
        guard meetingID == manifest.meetingID, manifestRevision == manifest.revision else {
            throw ContractValidationError.invalidRevision(manifestRevision)
        }
        guard manifestSHA256.lowercased() == manifest.sha256Hex() else {
            throw ContractValidationError.invalidSHA256("manifest.json")
        }
        guard cleanupAllowed else { throw ContractValidationError.cleanupNotAllowed }
        guard verifiedFiles.sorted(by: { $0.path < $1.path }) == manifest.files.sorted(by: { $0.path < $1.path }) else {
            throw ContractValidationError.missingMetadata
        }
    }
}
