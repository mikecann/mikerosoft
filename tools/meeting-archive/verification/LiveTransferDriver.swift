import Foundation
import MeetingArchiveCore

private enum LiveTransferDriverError: Error, CustomStringConvertible {
    case usage

    var description: String {
        "Usage: LiveTransferDriver LOCAL_BUNDLE HOST VALIDATION_ROOT"
    }
}

@main
private enum LiveTransferDriver {
    static func main() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count == 3 else { throw LiveTransferDriverError.usage }
        let source = URL(fileURLWithPath: arguments[0], isDirectory: true)
        let manifest = try ModelCodec.decoder.decode(
            TransferManifest.self,
            from: Data(contentsOf: source.appendingPathComponent("manifest.json"))
        )
        var configuration = ArchiveTransferConfiguration.bruceValidation
        configuration.host = arguments[1]
        configuration.incomingRoot = arguments[2] + "/incoming"
        configuration.archiveRoot = arguments[2] + "/meetings"
        configuration.workerDatabase = arguments[2] + "/worker.sqlite"
        let acknowledgement = try await ArchiveTransfer().upload(
            sourceDirectory: source,
            manifest: manifest,
            configuration: configuration
        )
        FileHandle.standardOutput.write(try ModelCodec.encoder.encode(acknowledgement))
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}

private extension ArchiveTransferConfiguration {
    static var bruceValidation: ArchiveTransferConfiguration {
        var configuration = ArchiveTransferConfiguration.bruce
        // The validation archive is isolated, while the installed worker and
        // Python environment remain the production runtime being exercised.
        configuration.workerPython = "/Volumes/CannMedia/MeetingArchive/runtime/venv/bin/python3"
        configuration.workerScript = "/Volumes/CannMedia/MeetingArchive/runtime/worker/worker.py"
        return configuration
    }
}
