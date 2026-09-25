import Compression
import Foundation

/// Reads files out of a zip archive.
///
/// Handles stored and deflated entries, which is everything Filmora writes
/// into a `.wfp`. No zip64, encryption or multi-disk archives: Filmora
/// projects are a few megabytes of JSON.
struct ZipReader {
    struct Entry: Equatable {
        var name: String
        /// 0 is stored, 8 is deflate.
        var method: UInt16
        var compressedSize: Int
        var uncompressedSize: Int
        var localHeaderOffset: Int
    }

    private let bytes: [UInt8]
    let entries: [Entry]

    init(url: URL) throws {
        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw ImportError.unreadable(url.path)
        }
        try self.init(data: data, name: url.lastPathComponent)
    }

    init(data: Data, name: String = "archive") throws {
        bytes = [UInt8](data)
        entries = try Self.readDirectory(bytes, name: name)
    }

    var names: [String] { entries.map(\.name) }

    func contains(_ name: String) -> Bool {
        entries.contains { $0.name == name }
    }

    /// The uncompressed contents of one entry.
    func read(_ name: String) throws -> Data {
        guard let entry = entries.first(where: { $0.name == name }) else {
            throw ImportError.unreadable("\(name) (not in the archive)")
        }
        let header = entry.localHeaderOffset
        guard header + 30 <= bytes.count, u32(header) == 0x0403_4B50 else {
            throw ImportError.unreadable("\(name) (bad local header)")
        }
        let start = header + 30 + Int(u16(header + 26)) + Int(u16(header + 28))
        let end = start + entry.compressedSize
        guard end <= bytes.count else { throw ImportError.unreadable("\(name) (truncated)") }
        let compressed = bytes[start..<end]
        switch entry.method {
        case 0:
            return Data(compressed)
        case 8:
            guard entry.uncompressedSize > 0 else { return Data() }
            var output = [UInt8](repeating: 0, count: entry.uncompressedSize)
            // COMPRESSION_ZLIB is raw DEFLATE (no zlib header), which is
            // exactly what zip stores.
            let written = compressed.withUnsafeBufferPointer { source in
                output.withUnsafeMutableBufferPointer { destination in
                    compression_decode_buffer(
                        destination.baseAddress!, entry.uncompressedSize,
                        source.baseAddress!, entry.compressedSize,
                        nil, COMPRESSION_ZLIB
                    )
                }
            }
            guard written == entry.uncompressedSize else {
                throw ImportError.unreadable("\(name) (inflated \(written) of \(entry.uncompressedSize) bytes)")
            }
            return Data(output)
        default:
            throw ImportError.unreadable("\(name) (compression method \(entry.method) isn't supported)")
        }
    }

    // MARK: - Central directory

    private static func readDirectory(_ bytes: [UInt8], name: String) throws -> [Entry] {
        func u16(_ at: Int) -> UInt16 { UInt16(bytes[at]) | UInt16(bytes[at + 1]) << 8 }
        func u32(_ at: Int) -> UInt32 { UInt32(u16(at)) | UInt32(u16(at + 2)) << 16 }

        // The end-of-central-directory record sits in the last 22 bytes
        // plus up to 64 KB of comment.
        guard bytes.count >= 22 else { throw ImportError.unreadable("\(name) (not a zip file)") }
        var eocd: Int?
        var i = bytes.count - 22
        let floor = max(0, bytes.count - 22 - 65_535)
        while i >= floor {
            if bytes[i] == 0x50, bytes[i + 1] == 0x4B, bytes[i + 2] == 0x05, bytes[i + 3] == 0x06 {
                eocd = i
                break
            }
            i -= 1
        }
        guard let eocd else { throw ImportError.unreadable("\(name) (not a zip file)") }
        let count = Int(u16(eocd + 10))
        var offset = Int(u32(eocd + 16))
        guard offset != 0xFFFF_FFFF else { throw ImportError.unreadable("\(name) (zip64 isn't supported)") }

        var entries: [Entry] = []
        for _ in 0..<count {
            guard offset + 46 <= bytes.count, u32(offset) == 0x0201_4B50 else {
                throw ImportError.unreadable("\(name) (bad central directory)")
            }
            let nameLength = Int(u16(offset + 28))
            let extraLength = Int(u16(offset + 30))
            let commentLength = Int(u16(offset + 32))
            let nameBytes = Array(bytes[(offset + 46)..<(offset + 46 + nameLength)])
            let entryName = String(bytes: nameBytes, encoding: .utf8) ?? String(decoding: nameBytes, as: UTF8.self)
            entries.append(Entry(
                name: entryName,
                method: u16(offset + 10),
                compressedSize: Int(u32(offset + 20)),
                uncompressedSize: Int(u32(offset + 24)),
                localHeaderOffset: Int(u32(offset + 42))
            ))
            offset += 46 + nameLength + extraLength + commentLength
        }
        return entries
    }

    private func u16(_ at: Int) -> UInt16 { UInt16(bytes[at]) | UInt16(bytes[at + 1]) << 8 }
    private func u32(_ at: Int) -> UInt32 { UInt32(u16(at)) | UInt32(u16(at + 2)) << 16 }
}
