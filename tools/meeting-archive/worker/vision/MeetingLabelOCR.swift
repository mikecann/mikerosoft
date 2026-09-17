import Darwin
import Foundation
import ImageIO
import Vision

private let maximumFrames = 12
private let maximumFrameBytes: UInt64 = 64 * 1024 * 1024

private struct BoundingBox: Codable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

private struct TextObservation: Codable {
    let text: String
    let confidence: Float
    let boundingBox: BoundingBox

    enum CodingKeys: String, CodingKey {
        case text, confidence
        case boundingBox = "bounding_box"
    }
}

private struct FrameResult: Codable {
    let path: String
    let observations: [TextObservation]
}

private struct OCRResponse: Codable {
    let schemaVersion = 1
    let frames: [FrameResult]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case frames
    }
}

private enum HelperError: Error, CustomStringConvertible {
    case invalidFrame(String)

    var description: String {
        switch self {
        case .invalidFrame(let reason): reason
        }
    }
}

private func isRegularNonSymlink(_ path: String) -> Bool {
    var metadata = stat()
    guard lstat(path, &metadata) == 0 else { return false }
    return (metadata.st_mode & S_IFMT) == S_IFREG
}

private func recognize(_ path: String) throws -> [TextObservation] {
    guard isRegularNonSymlink(path) else {
        throw HelperError.invalidFrame("frame is not a regular file")
    }
    let attributes = try FileManager.default.attributesOfItem(atPath: path)
    guard let size = attributes[.size] as? NSNumber,
          size.uint64Value > 0,
          size.uint64Value <= maximumFrameBytes else {
        throw HelperError.invalidFrame("frame size is outside the bounded range")
    }
    let url = URL(fileURLWithPath: path)
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        throw HelperError.invalidFrame("frame is not a readable image")
    }

    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false
    request.recognitionLanguages = ["en-US"]
    let handler = VNImageRequestHandler(cgImage: image, options: [:])
    try handler.perform([request])
    return (request.results ?? []).compactMap { observation in
        guard let candidate = observation.topCandidates(1).first else { return nil }
        let box = observation.boundingBox
        return TextObservation(
            text: candidate.string,
            confidence: candidate.confidence,
            boundingBox: BoundingBox(
                x: box.origin.x,
                y: box.origin.y,
                width: box.size.width,
                height: box.size.height
            )
        )
    }
}

private func writeError(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

private func main() -> Int32 {
    let arguments = Array(CommandLine.arguments.dropFirst())
    if arguments == ["--help"] {
        print("Usage: meeting-label-ocr FRAME.png [FRAME.png ...] (maximum 12)")
        return 0
    }
    guard !arguments.isEmpty, arguments.count <= maximumFrames else {
        writeError("Expected between 1 and 12 PNG frame paths.")
        return EX_USAGE
    }

    let frames = arguments.map { path in
        do {
            return FrameResult(path: path, observations: try recognize(path))
        } catch {
            // A single corrupt or partially written frame must not discard OCR
            // from the other bounded samples. Diagnostics contain no OCR text.
            writeError("Could not read frame \(URL(fileURLWithPath: path).lastPathComponent): \(error)")
            return FrameResult(path: path, observations: [])
        }
    }
    do {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(OCRResponse(frames: frames))
        data.append(0x0A)
        FileHandle.standardOutput.write(data)
        return 0
    } catch {
        writeError("Could not encode OCR response: \(error)")
        return EX_SOFTWARE
    }
}

exit(main())
