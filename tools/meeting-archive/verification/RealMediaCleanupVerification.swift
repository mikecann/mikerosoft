import Foundation
import MeetingArchiveCore

private struct VerificationFailure: Error, CustomStringConvertible {
    let description: String
}

private func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { throw VerificationFailure(description: message) }
}

private func regularFileDigests(in root: URL) throws -> [String: String] {
    let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL
    guard let enumerator = FileManager.default.enumerator(
        at: canonicalRoot,
        includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
        options: [.skipsHiddenFiles]
    ) else {
        throw VerificationFailure(description: "could not enumerate \(root.path)")
    }

    var result: [String: String] = [:]
    for case let url as URL in enumerator {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
        let canonicalURL = url.resolvingSymlinksInPath().standardizedFileURL
        let rootComponents = canonicalRoot.pathComponents
        let fileComponents = canonicalURL.pathComponents
        guard fileComponents.starts(with: rootComponents) else {
            throw VerificationFailure(description: "enumerated file escaped fixture copy: \(url.path)")
        }
        let relative = fileComponents.dropFirst(rootComponents.count).joined(separator: "/")
        result[relative] = try SpoolBundle.hash(url)
    }
    return result
}

private func verifyRetainedProof(
    source: URL,
    index: URL,
    manifest: TransferManifest,
    rawMetadata: Data,
    rawManifest: Data,
    rawAcknowledgement: Data,
    retainedDigests: [String: String]
) throws {
    let mediaPaths = Set(manifest.files.filter { $0.kind != .metadata }.map(\.path))
    for path in mediaPaths {
        try require(
            !FileManager.default.fileExists(atPath: source.appendingPathComponent(path).path),
            "cleanup retained manifest media \(path)"
        )
    }

    try require(
        Data(contentsOf: source.appendingPathComponent("metadata.json")) == rawMetadata,
        "source metadata bytes changed"
    )
    try require(
        Data(contentsOf: source.appendingPathComponent("manifest.json")) == rawManifest,
        "source manifest bytes changed"
    )
    try require(
        Data(contentsOf: source.appendingPathComponent("acknowledgement.json")) == rawAcknowledgement,
        "source acknowledgement bytes changed"
    )

    for (path, digest) in retainedDigests {
        let url = source.appendingPathComponent(path)
        try require(FileManager.default.fileExists(atPath: url.path), "cleanup removed unmanifested file \(path)")
        try require(SpoolBundle.hash(url) == digest, "cleanup changed unmanifested file \(path)")
    }

    try require(
        Data(contentsOf: index.appendingPathComponent("metadata.json")) == rawMetadata,
        "index metadata is not the exact accepted bytes"
    )
    try require(
        Data(contentsOf: index.appendingPathComponent("manifest.json")) == rawManifest,
        "index manifest is not the exact accepted bytes"
    )
    try require(
        Data(contentsOf: index.appendingPathComponent("acknowledgement.json")) == rawAcknowledgement,
        "index acknowledgement is not the exact Bruce receipt"
    )
    try require(
        Data(contentsOf: index.appendingPathComponent("cleanup-complete.json"))
            == Data("{\"schema_version\":1}".utf8),
        "cleanup completion marker is missing or malformed"
    )

    let remaining = Set(try regularFileDigests(in: source).keys)
    let expectedRemaining = Set(retainedDigests.keys).union([
        "metadata.json",
        "manifest.json",
        "acknowledgement.json",
    ])
    try require(remaining == expectedRemaining, "cleanup changed files outside the manifest media set")
}

@main
private enum RealMediaCleanupVerification {
    static func main() throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 3 else {
            throw VerificationFailure(description: "usage: real-media-cleanup <fixture-copy> <index-directory>")
        }
        let source = URL(fileURLWithPath: arguments[1], isDirectory: true).standardizedFileURL
        let index = URL(fileURLWithPath: arguments[2], isDirectory: true).standardizedFileURL

        let rawManifest = try Data(contentsOf: source.appendingPathComponent("manifest.json"))
        let rawAcknowledgement = try Data(contentsOf: source.appendingPathComponent("acknowledgement.json"))
        let rawMetadata = try Data(contentsOf: source.appendingPathComponent("metadata.json"))
        let manifest = try ModelCodec.decoder.decode(TransferManifest.self, from: rawManifest)
        let acknowledgement = try ModelCodec.decoder.decode(
            ArchiveAcknowledgement.self,
            from: rawAcknowledgement
        )

        try manifest.validate()
        try acknowledgement.validate(against: manifest)
        try require(
            acknowledgement.manifestSHA256 == SpoolBundle.hash(source.appendingPathComponent("manifest.json")),
            "manifest bytes do not match Bruce's acknowledged hash"
        )
        try ArchiveReceiptVerification.requireMediaValidation(rawAcknowledgement, manifest: manifest)

        for file in manifest.files {
            let url = source.appendingPathComponent(file.path)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? -1
            try require(size == file.sizeBytes, "fixture size does not match manifest for \(file.path)")
            try require(SpoolBundle.hash(url) == file.sha256, "fixture hash does not match manifest for \(file.path)")
        }

        let sentinel = source.appendingPathComponent("cleanup-verification-sentinel.txt")
        try Data("preserve this unmanifested sentinel\n".utf8).write(to: sentinel, options: .atomic)
        let allBefore = try regularFileDigests(in: source)
        let protectedPaths = Set(manifest.files.map(\.path)).union([
            "manifest.json",
            "acknowledgement.json",
        ])
        let retainedDigests = allBefore.filter { !protectedPaths.contains($0.key) }
        try require(
            retainedDigests[sentinel.lastPathComponent] != nil,
            "sentinel was not included in retention proof: \(retainedDigests.keys.sorted())"
        )

        try ArchiveCleanup.perform(source: source, index: index, acknowledgement: acknowledgement)
        try verifyRetainedProof(
            source: source,
            index: index,
            manifest: manifest,
            rawMetadata: rawMetadata,
            rawManifest: rawManifest,
            rawAcknowledgement: rawAcknowledgement,
            retainedDigests: retainedDigests
        )

        // A retry after a crash or app restart must preserve the same proof and
        // treat already-deleted media as a completed cleanup, not an error.
        try ArchiveCleanup.perform(source: source, index: index, acknowledgement: acknowledgement)
        try verifyRetainedProof(
            source: source,
            index: index,
            manifest: manifest,
            rawMetadata: rawMetadata,
            rawManifest: rawManifest,
            rawAcknowledgement: rawAcknowledgement,
            retainedDigests: retainedDigests
        )

        print("Real-media cleanup verification passed for \(manifest.meetingID.uuidString.lowercased()).")
        print("Deleted \(manifest.files.filter { $0.kind != .metadata }.count) copied media files; retained exact source and index proof bytes.")
    }
}
