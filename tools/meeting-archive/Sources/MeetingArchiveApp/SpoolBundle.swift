import CryptoKit
import Foundation
import MeetingArchiveCore

enum SpoolBundle {
    static let sources: [(String, ManifestFileKind)] = [("meeting-view.mov", .video), ("microphone.m4a", .microphoneAudio), ("incoming.m4a", .incomingAudio)]

    static func mediaFiles(in directory: URL) throws -> [(URL, ManifestFileKind)] {
        let files = try sources.compactMap { name, kind -> (URL, ManifestFileKind)? in
            let url = directory.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? 0) > 0 else {
                throw CaptureFailure.message("Capture contains an unsafe or empty media file: \(name)")
            }
            return (url, kind)
        }
        guard files.contains(where: { $0.1 == .microphoneAudio }) else {
            throw CaptureFailure.message("The microphone track is missing. The partial files have been retained for recovery.")
        }
        return files
    }

    /// Finalized inputs become immutable before transfer. Retries reuse the
    /// manifest bytes, rather than changing metadata under an in-flight upload.
    static func prepare(record: MeetingRecord, directory: URL) throws -> TransferManifest {
        let manifestURL = directory.appendingPathComponent("manifest.json")
        if FileManager.default.fileExists(atPath: manifestURL.path) {
            let manifest = try ModelCodec.decoder.decode(TransferManifest.self, from: Data(contentsOf: manifestURL))
            try manifest.validate()
            guard manifest.meetingID == record.id, manifest.revision == record.metadataRevision else {
                throw CaptureFailure.message("The queued manifest does not match this meeting revision.")
            }
            return manifest
        }
        let media = try mediaFiles(in: directory)
        let base = WorkerMeetingMetadata(meetingID: record.id, manifestRevision: record.metadataRevision, startedAt: record.startedAt, endedAt: record.endedAt, durationSeconds: record.endedAt.timeIntervalSince(record.startedAt), timezone: record.timezoneIdentifier, sourceApp: record.sourceApplication.bundleIdentifier)
        try base.validate()
        var metadata = try JSONSerialization.jsonObject(with: base.canonicalData()) as! [String: Any]
        metadata["title"] = record.title
        metadata["capture"] = try JSONSerialization.jsonObject(with: ModelCodec.encoder.encode(record))
        // Calendar attendees remain suggestions for the voice review UI.
        for (filename, key) in [("calendar.json", "calendar"), ("tracks.json", "tracks")] {
            if let data = try? Data(contentsOf: directory.appendingPathComponent(filename)) {
                metadata[key] = try JSONSerialization.jsonObject(with: data)
            }
        }
        let metadataURL = directory.appendingPathComponent("metadata.json")
        try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys, .withoutEscapingSlashes]).write(to: metadataURL, options: .atomic)
        let files = try (media + [(metadataURL, .metadata)]).map { url, kind in
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            return ManifestFile(path: url.lastPathComponent, sizeBytes: (attributes[.size] as! NSNumber).int64Value, sha256: try hash(url), kind: kind)
        }
        let manifest = TransferManifest(meetingID: record.id, revision: record.metadataRevision, files: files)
        try manifest.validate()
        try manifest.canonicalData().write(to: manifestURL, options: .atomic)
        return manifest
    }

    static func hash(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
