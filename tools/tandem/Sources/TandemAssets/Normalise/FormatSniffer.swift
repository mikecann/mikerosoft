import Foundation

/// File formats the library knows how to normalise, found from a file's
/// first bytes (and its extension when the bytes don't settle it).
public enum AssetFormat: String, Codable, Sendable {
    case wav, aiff, mp3, m4a, caf, flac, ogg
    case mov, mp4, webm
    case gif, webp, png, jpeg, heic, tiff, svg
    case lottie
    case ttf, otf, ttc, woff, woff2
    case cube
    case unknown

    public var isAudio: Bool { [.wav, .aiff, .mp3, .m4a, .caf, .flac, .ogg].contains(self) }
    public var isVideo: Bool { [.mov, .mp4, .webm].contains(self) }
    public var isStillOrAnimatedImage: Bool { [.gif, .webp, .png, .jpeg, .heic, .tiff].contains(self) }
    public var isFont: Bool { [.ttf, .otf, .ttc, .woff, .woff2].contains(self) }

    /// The usual file extension.
    public var fileExtension: String {
        switch self {
        case .jpeg: return "jpg"
        case .lottie: return "json"
        case .unknown: return "bin"
        default: return rawValue
        }
    }
}

/// Recognising files by their first bytes.
public enum FormatSniffer {
    /// Works out a file's format from its contents, falling back to the
    /// extension.
    public static func format(of url: URL) -> AssetFormat {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return fromExtension(url.pathExtension) }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 4096)) ?? Data()
        let sniffed = format(head: head, fileExtension: url.pathExtension)
        if sniffed == .unknown, head.first == UInt8(ascii: "{") || head.first == UInt8(ascii: "[") {
            // Lottie files can be large; only parse them when the head
            // looks like JSON.
            if isLottie(url) { return .lottie }
        }
        return sniffed
    }

    static func format(head: Data, fileExtension: String) -> AssetFormat {
        let bytes = [UInt8](head.prefix(64))
        func ascii(_ offset: Int, _ length: Int) -> String {
            guard bytes.count >= offset + length else { return "" }
            return String(decoding: bytes[offset..<(offset + length)], as: UTF8.self)
        }
        let ext = fileExtension.lowercased()
        switch ascii(0, 4) {
        case "RIFF":
            switch ascii(8, 4) {
            case "WAVE": return .wav
            case "WEBP": return .webp
            default: break
            }
        case "RF64": return .wav
        case "FORM": return .aiff
        case "fLaC": return .flac
        case "OggS": return .ogg
        case "caff": return .caf
        case "GIF8": return .gif
        case "wOFF": return .woff
        case "wOF2": return .woff2
        case "OTTO": return .otf
        case "ttcf": return .ttc
        case "true": return .ttf
        default: break
        }
        if bytes.starts(with: [0x00, 0x01, 0x00, 0x00]) { return .ttf }
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return .png }
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return .jpeg }
        if bytes.starts(with: [0x1A, 0x45, 0xDF, 0xA3]) { return .webm }
        if bytes.starts(with: [0x49, 0x49, 0x2A, 0x00]) || bytes.starts(with: [0x4D, 0x4D, 0x00, 0x2A]) { return .tiff }
        if ascii(0, 3) == "ID3" { return .mp3 }
        if bytes.count >= 2, bytes[0] == 0xFF, bytes[1] & 0xE0 == 0xE0, ext != "aac" { return .mp3 }
        if ascii(4, 4) == "ftyp" {
            let brand = ascii(8, 4)
            if ["heic", "heix", "mif1", "msf1", "avif"].contains(brand) { return .heic }
            if brand == "qt  " { return .mov }
            if brand.hasPrefix("M4A") || brand.hasPrefix("M4B") || ext == "m4a" { return .m4a }
            return ext == "mov" ? .mov : .mp4
        }
        // QuickTime files without an ftyp atom start with other atoms.
        if ["moov", "mdat", "wide", "free", "skip"].contains(ascii(4, 4)) { return ext == "mp4" ? .mp4 : .mov }
        if let text = String(data: head, encoding: .utf8) ?? String(data: head, encoding: .isoLatin1) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}")))
            if trimmed.hasPrefix("<svg") || (trimmed.hasPrefix("<?xml") || trimmed.hasPrefix("<!--") || trimmed.hasPrefix("<!DOCTYPE svg")) && trimmed.contains("<svg") {
                return .svg
            }
            if ext == "cube" || trimmed.hasPrefix("LUT_3D_SIZE") || trimmed.contains("\nLUT_3D_SIZE") { return .cube }
        }
        return fromExtension(ext)
    }

    /// A Lottie animation is JSON with layers, a frame rate and in and out
    /// points.
    static func isLottie(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return object["layers"] is [Any] && object["fr"] != nil && object["op"] != nil
    }

    static func fromExtension(_ ext: String) -> AssetFormat {
        switch ext.lowercased() {
        case "wav", "wave": return .wav
        case "aif", "aiff", "aifc": return .aiff
        case "mp3": return .mp3
        case "m4a", "aac": return .m4a
        case "caf": return .caf
        case "flac": return .flac
        case "ogg", "oga", "opus": return .ogg
        case "mov", "qt": return .mov
        case "mp4", "m4v": return .mp4
        case "webm", "mkv": return .webm
        case "gif": return .gif
        case "webp": return .webp
        case "png": return .png
        case "jpg", "jpeg": return .jpeg
        case "heic", "heif", "avif": return .heic
        case "tif", "tiff": return .tiff
        case "svg": return .svg
        case "ttf": return .ttf
        case "otf": return .otf
        case "ttc": return .ttc
        case "woff": return .woff
        case "woff2": return .woff2
        case "cube": return .cube
        default: return .unknown
        }
    }
}
