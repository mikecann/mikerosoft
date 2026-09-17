import CryptoKit
import Foundation

private enum ContractFixtureError: Error, CustomStringConvertible {
    case usage
    case invalidAcknowledgement(String)

    var description: String {
        switch self {
        case .usage:
            "Usage: ContractRoundTrip emit BUNDLE_DIR | validate BUNDLE_DIR ACKNOWLEDGEMENT_JSON"
        case .invalidAcknowledgement(let message):
            "Invalid worker acknowledgement: \(message)"
        }
    }
}

@main
private enum ContractRoundTrip {
    static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.count == 2, arguments[0] == "emit" {
            try emitFixture(at: URL(fileURLWithPath: arguments[1], isDirectory: true))
        } else if arguments.count == 3, arguments[0] == "validate" {
            try validateAcknowledgement(
                bundle: URL(fileURLWithPath: arguments[1], isDirectory: true),
                acknowledgement: URL(fileURLWithPath: arguments[2])
            )
        } else {
            throw ContractFixtureError.usage
        }
    }

    private static func emitFixture(at directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let meetingID = UUID(uuidString: "7c3f6176-b12c-4b25-8e81-0dafb231f984")!
        let metadata = WorkerMeetingMetadata(
            meetingID: meetingID,
            manifestRevision: 1,
            startedAt: Date(timeIntervalSince1970: 1_789_128_000),
            endedAt: Date(timeIntervalSince1970: 1_789_128_090),
            durationSeconds: 90,
            timezone: "Australia/Perth",
            sourceApp: "com.google.Chrome"
        )
        try metadata.validate()
        let metadataData = try metadata.canonicalData()
        let microphoneData = Data("bounded microphone fixture\n".utf8)
        let incomingData = Data("bounded incoming fixture\n".utf8)
        let videoData = Data("bounded meeting view fixture\n".utf8)

        let payloads: [(String, Data, ManifestFileKind)] = [
            ("metadata.json", metadataData, .metadata),
            ("microphone.m4a", microphoneData, .microphoneAudio),
            ("incoming.m4a", incomingData, .incomingAudio),
            ("meeting-view.mov", videoData, .video),
        ]
        for (name, data, _) in payloads {
            try data.write(to: directory.appendingPathComponent(name), options: .atomic)
        }

        let manifest = TransferManifest(
            meetingID: meetingID,
            revision: 1,
            files: payloads.map { name, data, kind in
                ManifestFile(
                    path: name,
                    sizeBytes: Int64(data.count),
                    sha256: sha256(data),
                    kind: kind
                )
            }
        )
        try manifest.validate()
        try manifest.canonicalData().write(
            to: directory.appendingPathComponent("manifest.json"),
            options: .atomic
        )
        print(manifest.sha256Hex())
    }

    private static func validateAcknowledgement(bundle: URL, acknowledgement: URL) throws {
        let manifestData = try Data(contentsOf: bundle.appendingPathComponent("manifest.json"))
        let manifest = try ModelCodec.decoder.decode(TransferManifest.self, from: manifestData)
        guard manifestData == (try manifest.canonicalData()) else {
            throw ContractFixtureError.invalidAcknowledgement("manifest bytes are not canonical")
        }
        let acknowledgement = try ModelCodec.decoder.decode(
            ArchiveAcknowledgement.self,
            from: Data(contentsOf: acknowledgement)
        )
        try acknowledgement.validate(against: manifest)
        guard acknowledgement.manifestSHA256 == manifest.sha256Hex() else {
            throw ContractFixtureError.invalidAcknowledgement("manifest digest changed across the worker boundary")
        }
        print("validated \(acknowledgement.meetingID.canonicalString) revision \(acknowledgement.manifestRevision)")
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
