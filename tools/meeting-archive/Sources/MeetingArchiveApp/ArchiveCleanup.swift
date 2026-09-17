import CryptoKit
import Foundation
import MeetingArchiveCore

enum ArchiveCleanup {
    static func perform(source: URL, index: URL, acknowledgement: ArchiveAcknowledgement) throws {
        let root = try canonicalSpoolRoot(source)
        let manifestURL = try requiredRegularFile(root: root, relativePath: "manifest.json")
        let rawManifest = try Data(contentsOf: manifestURL)
        let manifest = try ModelCodec.decoder.decode(TransferManifest.self, from: rawManifest)
        try acknowledgement.validate(against: manifest)
        guard acknowledgement.manifestSHA256.lowercased() == sha256(rawManifest) else {
            throw ArchiveTransferError.invalidAcknowledgement(
                "Persisted manifest bytes do not match the acknowledged manifest hash"
            )
        }

        let receiptURL = try requiredRegularFile(root: root, relativePath: "acknowledgement.json")
        let rawReceipt = try Data(contentsOf: receiptURL)
        let persistedAcknowledgement = try ModelCodec.decoder.decode(
            ArchiveAcknowledgement.self,
            from: rawReceipt
        )
        try persistedAcknowledgement.validate(against: manifest)
        guard persistedAcknowledgement == acknowledgement else {
            throw ArchiveTransferError.invalidAcknowledgement(
                "Persisted acknowledgement identity differs from the accepted transfer result"
            )
        }
        try ArchiveReceiptVerification.requireMediaValidation(rawReceipt, manifest: manifest)

        guard let metadataEntry = manifest.files.first(where: {
            $0.path == "metadata.json" && $0.kind == .metadata
        }) else {
            throw ArchiveTransferError.invalidAcknowledgement("Manifest metadata is missing")
        }
        let metadataURL = try requiredRegularFile(root: root, relativePath: metadataEntry.path)
        try verify(metadataURL, file: metadataEntry)
        let metadata = try Data(contentsOf: metadataURL)

        // Validate the full deletion set before removing its first member. A
        // malformed later path can therefore never cause partial unsafe cleanup.
        var deletionSet: [(ManifestFile, URL)] = []
        for file in manifest.files where file.kind != .metadata {
            guard let candidate = try optionalRegularFile(root: root, relativePath: file.path) else {
                continue // A prior cleanup attempt may already have removed it.
            }
            try verify(candidate, file: file)
            deletionSet.append((file, candidate))
        }

        try FileManager.default.createDirectory(
            at: index,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try metadata.write(
            to: index.appendingPathComponent("metadata.json"),
            options: .atomic
        )
        try rawManifest.write(
            to: index.appendingPathComponent("manifest.json"),
            options: .atomic
        )
        // Keep the exact worker JSON, including media_validation evidence that
        // ArchiveAcknowledgement intentionally ignores when decoding.
        try rawReceipt.write(
            to: index.appendingPathComponent("acknowledgement.json"),
            options: .atomic
        )

        for (file, previouslyValidatedURL) in deletionSet {
            // Re-resolve immediately before deletion so a replaced parent or
            // file cannot reuse an earlier safe-path decision.
            guard let current = try optionalRegularFile(root: root, relativePath: file.path) else {
                continue
            }
            guard current.standardizedFileURL == previouslyValidatedURL.standardizedFileURL else {
                throw ArchiveTransferError.unsafeLocalPath(file.path)
            }
            try verify(current, file: file)
            try FileManager.default.removeItem(at: current)
        }
        try Data("{\"schema_version\":1}".utf8).write(
            to: index.appendingPathComponent("cleanup-complete.json"),
            options: .atomic
        )
    }

    private static func canonicalSpoolRoot(_ source: URL) throws -> URL {
        let supplied = source.standardizedFileURL
        let suppliedValues = try supplied.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey,
        ])
        guard suppliedValues.isDirectory == true, suppliedValues.isSymbolicLink != true else {
            throw ArchiveTransferError.unsafeLocalPath(".")
        }
        // Resolve once at the root. This accepts macOS's legitimate
        // /var -> /private/var alias, then treats the canonical path as the
        // boundary beneath which every manifest component must remain real.
        let canonical = supplied.resolvingSymlinksInPath().standardizedFileURL
        let canonicalValues = try canonical.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey,
        ])
        guard canonicalValues.isDirectory == true, canonicalValues.isSymbolicLink != true else {
            throw ArchiveTransferError.unsafeLocalPath(".")
        }
        return canonical
    }

    private static func requiredRegularFile(root: URL, relativePath: String) throws -> URL {
        guard let value = try checkedRegularFile(
            root: root,
            relativePath: relativePath,
            allowMissing: false
        ) else {
            throw ArchiveTransferError.fileMissing(relativePath)
        }
        return value
    }

    private static func optionalRegularFile(root: URL, relativePath: String) throws -> URL? {
        try checkedRegularFile(root: root, relativePath: relativePath, allowMissing: true)
    }

    private static func checkedRegularFile(
        root: URL,
        relativePath: String,
        allowMissing: Bool
    ) throws -> URL? {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else {
            throw ArchiveTransferError.unsafeLocalPath(relativePath)
        }

        var candidate = root
        for (offset, component) in components.enumerated() {
            candidate.appendPathComponent(String(component), isDirectory: offset < components.count - 1)
            let values: URLResourceValues
            do {
                values = try candidate.resourceValues(forKeys: [
                    .isDirectoryKey,
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                ])
            } catch let error as CocoaError where allowMissing && (error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile) {
                return nil
            }
            guard values.isSymbolicLink != true else {
                throw ArchiveTransferError.unsafeLocalPath(relativePath)
            }
            if offset < components.count - 1 {
                guard values.isDirectory == true else {
                    throw ArchiveTransferError.unsafeLocalPath(relativePath)
                }
            } else {
                guard values.isRegularFile == true else {
                    throw ArchiveTransferError.unsafeLocalPath(relativePath)
                }
            }
        }

        let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard resolved.path.hasPrefix(rootPrefix) else {
            throw ArchiveTransferError.unsafeLocalPath(relativePath)
        }
        return candidate
    }

    private static func verify(_ url: URL, file: ManifestFile) throws {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard Int64(values.fileSize ?? -1) == file.sizeBytes else {
            throw ArchiveTransferError.fileSizeMismatch(file.path)
        }
        guard try SpoolBundle.hash(url) == file.sha256 else {
            throw ArchiveTransferError.fileHashMismatch(file.path)
        }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
