import CryptoKit
import Darwin
import Foundation
import MeetingArchiveCore

struct ArchiveProcessRequest: Equatable, Sendable {
    var executable: URL
    var arguments: [String]
    var timeout: TimeInterval
}

struct ArchiveProcessResult: Equatable, Sendable {
    var exitCode: Int32
    var stdout: Data
    var stderr: String
}

protocol ArchiveProcessRunning: Sendable {
    func run(_ request: ArchiveProcessRequest) async throws -> ArchiveProcessResult
}

struct FoundationArchiveProcessRunner: ArchiveProcessRunning {
    private let maximumStandardOutputBytes = 1_048_576
    private let maximumStandardErrorBytes = 65_536

    func run(_ request: ArchiveProcessRequest) async throws -> ArchiveProcessResult {
        try await Task.detached(priority: .utility) {
            try runSynchronously(
                request,
                maximumStandardOutputBytes: maximumStandardOutputBytes,
                maximumStandardErrorBytes: maximumStandardErrorBytes
            )
        }.value
    }

    private func runSynchronously(
        _ request: ArchiveProcessRequest,
        maximumStandardOutputBytes: Int,
        maximumStandardErrorBytes: Int
    ) throws -> ArchiveProcessResult {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-archive-process-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let standardOutputURL = temporaryDirectory.appendingPathComponent("stdout")
        let standardErrorURL = temporaryDirectory.appendingPathComponent("stderr")
        FileManager.default.createFile(atPath: standardOutputURL.path, contents: nil)
        FileManager.default.createFile(atPath: standardErrorURL.path, contents: nil)
        let standardOutput = try FileHandle(forWritingTo: standardOutputURL)
        let standardError = try FileHandle(forWritingTo: standardErrorURL)
        defer {
            try? standardOutput.close()
            try? standardError.close()
        }

        let process = Process()
        process.executableURL = request.executable
        process.arguments = request.arguments
        process.standardOutput = standardOutput
        process.standardError = standardError
        do {
            try process.run()
        } catch {
            throw ArchiveTransferError.processLaunchFailed(error.localizedDescription)
        }

        let deadline = ProcessInfo.processInfo.systemUptime + request.timeout
        while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            let terminationDeadline = ProcessInfo.processInfo.systemUptime + 1
            while process.isRunning && ProcessInfo.processInfo.systemUptime < terminationDeadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            throw ArchiveTransferError.processTimedOut(request.executable.path)
        }
        process.waitUntilExit()
        try standardOutput.synchronize()
        try standardError.synchronize()

        let output = try readPrefix(of: standardOutputURL, maximumBytes: maximumStandardOutputBytes)
        let error = try readSuffix(of: standardErrorURL, maximumBytes: maximumStandardErrorBytes)
        return ArchiveProcessResult(
            exitCode: process.terminationStatus,
            stdout: output,
            stderr: String(decoding: error, as: UTF8.self)
        )
    }

    private func readPrefix(of url: URL, maximumBytes: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes else { throw ArchiveTransferError.processOutputTooLarge(url.lastPathComponent) }
        return data
    }

    private func readSuffix(of url: URL, maximumBytes: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let length = try handle.seekToEnd()
        if length > UInt64(maximumBytes) {
            try handle.seek(toOffset: length - UInt64(maximumBytes))
        } else {
            try handle.seek(toOffset: 0)
        }
        return try handle.readToEnd() ?? Data()
    }
}

struct ArchiveTransferConfiguration: Equatable, Sendable {
    var host: String
    var incomingRoot: String
    var archiveRoot: String
    var workerPython: String
    var workerScript: String
    var workerDatabase: String
    var sshExecutable: URL
    var rsyncExecutable: URL
    var commandTimeout: TimeInterval
    var transferTimeout: TimeInterval
    var workerTimeout: TimeInterval

    static let bruce = ArchiveTransferConfiguration(
        host: "bruce",
        incomingRoot: "/Volumes/CannMedia/MeetingArchive/incoming",
        archiveRoot: "/Volumes/CannMedia/MeetingArchive/meetings",
        workerPython: "/Volumes/CannMedia/MeetingArchive/runtime/venv/bin/python3",
        workerScript: "/Volumes/CannMedia/MeetingArchive/runtime/worker/worker.py",
        workerDatabase: "/Volumes/CannMedia/MeetingArchive/worker.sqlite",
        sshExecutable: URL(fileURLWithPath: "/usr/bin/ssh"),
        rsyncExecutable: URL(fileURLWithPath: "/usr/bin/rsync"),
        commandTimeout: 15,
        transferTimeout: 7_200,
        workerTimeout: 7_200
    )

    func validate() throws {
        guard !host.isEmpty,
              host.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-")).contains($0) })
        else { throw ArchiveTransferError.unsafeConfiguration("host") }
        for (name, path) in [
            ("incomingRoot", incomingRoot),
            ("archiveRoot", archiveRoot),
            ("workerPython", workerPython),
            ("workerScript", workerScript),
            ("workerDatabase", workerDatabase),
        ] {
            guard path.hasPrefix("/Volumes/CannMedia/MeetingArchive/"), isSafeRemotePath(path) else {
                throw ArchiveTransferError.unsafeConfiguration(name)
            }
        }
        guard commandTimeout > 0, transferTimeout > 0, workerTimeout > 0 else {
            throw ArchiveTransferError.unsafeConfiguration("timeout")
        }
    }

    private func isSafeRemotePath(_ path: String) -> Bool {
        path.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "/._-")).contains($0)
        } && !path.contains("..")
    }
}

enum ArchiveTransferError: Error, Equatable, CustomStringConvertible {
    case unsafeConfiguration(String)
    case manifestBytesChanged
    case fileMissing(String)
    case unsafeLocalPath(String)
    case fileSizeMismatch(String)
    case fileHashMismatch(String)
    case processLaunchFailed(String)
    case processTimedOut(String)
    case processOutputTooLarge(String)
    case commandFailed(executable: String, exitCode: Int32, stderr: String)
    case remoteVolumeMismatch(actual: String)
    case invalidRemoteStorage(String)
    case invalidAcknowledgement(String)
    case unsupportedArtifactPath(String)

    var description: String {
        switch self {
        case .unsafeConfiguration(let field): "Unsafe archive transfer configuration: \(field)"
        case .manifestBytesChanged: "manifest.json bytes do not match the transfer manifest"
        case .fileMissing(let path): "Manifest file is missing: \(path)"
        case .unsafeLocalPath(let path): "Manifest file escapes the source directory or uses a symlink: \(path)"
        case .fileSizeMismatch(let path): "Manifest file size changed: \(path)"
        case .fileHashMismatch(let path): "Manifest file hash changed: \(path)"
        case .processLaunchFailed(let message): "Could not launch archive process: \(message)"
        case .processTimedOut(let executable): "Archive process timed out: \(executable)"
        case .processOutputTooLarge(let stream): "Archive process produced too much \(stream)"
        case .commandFailed(let executable, let code, let stderr): "\(executable) failed with \(code): \(stderr)"
        case .remoteVolumeMismatch(let actual): "Bruce mounted an unexpected CannMedia volume UUID: \(actual)"
        case .invalidRemoteStorage(let message): "Bruce Meeting Archive storage preflight failed: \(message)"
        case .invalidAcknowledgement(let message): "Bruce returned an invalid acknowledgement: \(message)"
        case .unsupportedArtifactPath(let path): "Unsupported archive artifact path: \(path)"
        }
    }
}

actor ArchiveTransfer {
    static let cannMediaVolumeRoot = "/Volumes/CannMedia"
    static let cannMediaVolumeUUID = "5CCB1D81-5A98-4C4A-9E2C-3E10B23F1B46"

    private let processRunner: any ArchiveProcessRunning

    init(processRunner: any ArchiveProcessRunning = FoundationArchiveProcessRunner()) {
        self.processRunner = processRunner
    }

    func upload(
        sourceDirectory: URL,
        manifest: TransferManifest,
        configuration: ArchiveTransferConfiguration = .bruce
    ) async throws -> ArchiveAcknowledgement {
        try configuration.validate()
        try manifest.validate()
        let rawManifestSHA256 = try verifyLocalBundle(sourceDirectory: sourceDirectory, manifest: manifest)

        let stagingPath = "\(configuration.incomingRoot)/\(manifest.meetingID.uuidString.lowercased())/r\(manifest.revision)"
        let sshPrefix = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "--", configuration.host]
        try await preflightRemoteStorage(configuration: configuration, sshPrefix: sshPrefix)
        _ = try await runChecked(
            ArchiveProcessRequest(
                executable: configuration.sshExecutable,
                arguments: sshPrefix + ["mkdir", "-p", "--", stagingPath],
                timeout: configuration.commandTimeout
            )
        )

        let sourcePath = sourceDirectory.standardizedFileURL.path.hasSuffix("/")
            ? sourceDirectory.standardizedFileURL.path
            : sourceDirectory.standardizedFileURL.path + "/"
        _ = try await runChecked(
            ArchiveProcessRequest(
                executable: configuration.rsyncExecutable,
                arguments: [
                    "--archive",
                    "--partial",
                    "--",
                    sourcePath,
                    "\(configuration.host):\(stagingPath)/",
                ],
                timeout: configuration.transferTimeout
            )
        )

        let workerResult = try await runChecked(
            ArchiveProcessRequest(
                executable: configuration.sshExecutable,
                arguments: sshPrefix + [
                    configuration.workerPython,
                    configuration.workerScript,
                    "accept",
                    "--incoming", stagingPath,
                    "--archive-root", configuration.archiveRoot,
                    "--db", configuration.workerDatabase,
                    "--manifest-sha256", rawManifestSHA256,
                    "--validate-media",
                ],
                timeout: configuration.workerTimeout
            )
        )

        let acknowledgement: ArchiveAcknowledgement
        do {
            acknowledgement = try ModelCodec.decoder.decode(ArchiveAcknowledgement.self, from: workerResult.stdout)
            try acknowledgement.validate(against: manifest)
            try ArchiveReceiptVerification.requireMediaValidation(workerResult.stdout, manifest: manifest)
            guard acknowledgement.manifestSHA256.lowercased() == rawManifestSHA256 else {
                throw ArchiveTransferError.invalidAcknowledgement("manifest_sha256 does not match raw manifest bytes")
            }
        } catch let error as ArchiveTransferError {
            throw error
        } catch {
            throw ArchiveTransferError.invalidAcknowledgement(error.localizedDescription)
        }

        // This durable receipt is written before the caller considers any
        // separately controlled local-media cleanup.
        let acknowledgementURL = sourceDirectory.appendingPathComponent("acknowledgement.json")
        try workerResult.stdout.write(to: acknowledgementURL, options: .atomic)
        return acknowledgement
    }

    func fetch(
        relativePath: String,
        meetingID: UUID,
        destination: URL,
        configuration: ArchiveTransferConfiguration = .bruce
    ) async throws -> URL {
        try configuration.validate()
        guard Self.isSupportedArtifact(relativePath) else {
            throw ArchiveTransferError.unsupportedArtifactPath(relativePath)
        }

        let sshPrefix = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "--", configuration.host]
        let locateResult = try await runChecked(
            ArchiveProcessRequest(
                executable: configuration.sshExecutable,
                arguments: sshPrefix + [
                    configuration.workerPython,
                    configuration.workerScript,
                    "locate",
                    "--meeting-id", meetingID.uuidString.lowercased(),
                    "--archive-root", configuration.archiveRoot,
                    "--db", configuration.workerDatabase,
                ],
                timeout: configuration.commandTimeout
            )
        )
        let located: LocatedArchive
        do {
            located = try ModelCodec.decoder.decode(LocatedArchive.self, from: locateResult.stdout)
        } catch {
            throw ArchiveTransferError.invalidAcknowledgement(error.localizedDescription)
        }
        guard located.schemaVersion == 1,
              located.meetingID == meetingID,
              located.archivePath.hasPrefix(configuration.archiveRoot + "/"),
              Self.isSafeResolvedArchivePath(located.archivePath)
        else {
            throw ArchiveTransferError.invalidAcknowledgement("locate returned an unsafe archive path")
        }

        let standardizedDestination = destination.standardizedFileURL
        try FileManager.default.createDirectory(
            at: standardizedDestination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let remotePath = located.archivePath + "/" + relativePath
        _ = try await runChecked(
            ArchiveProcessRequest(
                executable: configuration.rsyncExecutable,
                arguments: [
                    "--archive",
                    "--partial",
                    "--",
                    "\(configuration.host):\(remotePath)",
                    standardizedDestination.path,
                ],
                timeout: configuration.transferTimeout
            )
        )
        return standardizedDestination
    }

    private func preflightRemoteStorage(
        configuration: ArchiveTransferConfiguration,
        sshPrefix: [String]
    ) async throws {
        let volumeResult = try await runChecked(
            ArchiveProcessRequest(
                executable: configuration.sshExecutable,
                arguments: sshPrefix + [
                    "/usr/sbin/diskutil",
                    "info",
                    "-plist",
                    Self.cannMediaVolumeRoot,
                ],
                timeout: configuration.commandTimeout
            )
        )
        let volumeInformation: [String: Any]
        do {
            guard let value = try PropertyListSerialization.propertyList(
                from: volumeResult.stdout,
                options: [],
                format: nil
            ) as? [String: Any] else {
                throw ArchiveTransferError.invalidRemoteStorage("diskutil returned no property list")
            }
            volumeInformation = value
        } catch let error as ArchiveTransferError {
            throw error
        } catch {
            throw ArchiveTransferError.invalidRemoteStorage("diskutil returned invalid property-list data")
        }
        guard let actualUUID = volumeInformation["VolumeUUID"] as? String else {
            throw ArchiveTransferError.invalidRemoteStorage("diskutil did not return VolumeUUID")
        }
        guard actualUUID.caseInsensitiveCompare(Self.cannMediaVolumeUUID) == .orderedSame else {
            throw ArchiveTransferError.remoteVolumeMismatch(actual: actualUUID)
        }

        let rootsResult = try await runChecked(
            ArchiveProcessRequest(
                executable: configuration.sshExecutable,
                arguments: sshPrefix + [
                    "/usr/bin/stat",
                    "-f",
                    "%d:%HT",
                    Self.cannMediaVolumeRoot,
                    configuration.incomingRoot,
                    configuration.archiveRoot,
                ],
                timeout: configuration.commandTimeout
            )
        )
        guard let output = String(data: rootsResult.stdout, encoding: .utf8) else {
            throw ArchiveTransferError.invalidRemoteStorage("stat returned non-UTF-8 output")
        }
        let lines = output.split(whereSeparator: \.isNewline).map(String.init)
        guard lines.count == 3 else {
            throw ArchiveTransferError.invalidRemoteStorage("stat did not report all required roots")
        }
        var deviceIDs = Set<String>()
        for line in lines {
            let fields = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard fields.count == 2,
                  !fields[0].isEmpty,
                  fields[0].allSatisfy(\.isNumber),
                  fields[1] == "Directory"
            else {
                throw ArchiveTransferError.invalidRemoteStorage("a required root is not a real directory")
            }
            deviceIDs.insert(String(fields[0]))
        }
        guard deviceIDs.count == 1 else {
            throw ArchiveTransferError.invalidRemoteStorage("required roots are not on the CannMedia filesystem")
        }
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

    private func verifyLocalBundle(sourceDirectory: URL, manifest: TransferManifest) throws -> String {
        let root = sourceDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let manifestURL = root.appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw ArchiveTransferError.fileMissing("manifest.json")
        }
        let manifestBytes = try Data(contentsOf: manifestURL, options: .mappedIfSafe)
        guard manifestBytes == (try manifest.canonicalData()) else { throw ArchiveTransferError.manifestBytesChanged }

        for file in manifest.files {
            let candidate = root.appendingPathComponent(file.path).standardizedFileURL
            let resolved = candidate.resolvingSymlinksInPath()
            guard resolved.path.hasPrefix(root.path + "/"), resolved.path == candidate.path else {
                throw ArchiveTransferError.unsafeLocalPath(file.path)
            }
            guard FileManager.default.fileExists(atPath: candidate.path) else {
                throw ArchiveTransferError.fileMissing(file.path)
            }
            let values = try candidate.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw ArchiveTransferError.unsafeLocalPath(file.path)
            }
            guard Int64(values.fileSize ?? -1) == file.sizeBytes else {
                throw ArchiveTransferError.fileSizeMismatch(file.path)
            }
            guard try sha256Hex(of: candidate) == file.sha256 else {
                throw ArchiveTransferError.fileHashMismatch(file.path)
            }
        }
        return SHA256.hash(data: manifestBytes).map { String(format: "%02x", $0) }.joined()
    }

    private func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            digest.update(data: chunk)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func isSupportedArtifact(_ path: String) -> Bool {
        if path == "playback/meeting.mp4" || path == "speakers/assignments.json" { return true }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 3,
              components[0] == "transcripts",
              components[1].first == "v",
              let version = Int(components[1].dropFirst()),
              version >= 1
        else { return false }
        return ["transcript.json", "transcript.md", "transcript.vtt"].contains(String(components[2]))
    }

    private static func isSafeResolvedArchivePath(_ path: String) -> Bool {
        path.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "/._-")).contains($0)
        } && !path.contains("..")
    }
}

enum ArchiveReceiptVerification {
    static func requireMediaValidation(_ data: Data, manifest: TransferManifest) throws {
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let validation = value["media_validation"] as? [String: Any],
              validation["status"] as? String == "passed", validation["full_decode"] as? Bool == true,
              let files = validation["files"] as? [[String: Any]] else {
            throw ArchiveTransferError.invalidAcknowledgement("Bruce did not confirm full media validation")
        }
        let expected = Set(manifest.files.filter { $0.kind != .metadata }.map(\.path))
        guard files.count == expected.count, Set(files.compactMap { $0["path"] as? String }) == expected,
              files.allSatisfy({ file in
                  guard let duration = file["duration_seconds"] as? Double else { return false }
                  return duration.isFinite && duration > 0 && file["full_decode"] as? Bool == true
              }) else { throw ArchiveTransferError.invalidAcknowledgement("Media validation does not cover every preserved track") }
    }
}

private struct LocatedArchive: Codable {
    var schemaVersion: Int
    var meetingID: UUID
    var archivePath: String

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case meetingID = "meeting_id"
        case archivePath = "archive_path"
    }
}
