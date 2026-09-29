import Foundation

/// Fonts for tests. A copy of a macOS font would be found whether it was
/// registered or not, so tests make one with a family name nothing else on
/// the Mac has, by rewriting a TrueType font's name table.
enum FontFixtures {
    /// A plain TrueType font (not a collection) that ships with macOS.
    static func systemTrueType() -> URL? {
        let candidates = [
            "/System/Library/Fonts/Supplemental/Courier New.ttf",
            "/System/Library/Fonts/Supplemental/Georgia.ttf",
            "/System/Library/Fonts/Supplemental/Arial.ttf"
        ]
        return candidates.map(URL.init(fileURLWithPath:)).first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// A family name no other font uses.
    static func uniqueFamily() -> String {
        "Tandem Test " + String((0..<8).map { _ in "abcdefghijklmnopqrstuvwxyz".randomElement()! }).capitalized
    }

    /// The PostScript name `renamed` gives `family`.
    static func postScriptName(of family: String) -> String {
        family.replacingOccurrences(of: " ", with: "") + "-Regular"
    }

    /// Writes `source` to `destination` as family `family`.
    static func renamed(_ source: URL, family: String, to destination: URL) throws {
        let data = try Data(contentsOf: source)
        func u16(_ o: Int) -> Int { Int(data[o]) << 8 | Int(data[o + 1]) }
        func u32(_ o: Int) -> Int { Int(data[o]) << 24 | Int(data[o + 1]) << 16 | Int(data[o + 2]) << 8 | Int(data[o + 3]) }
        var tables: [(tag: String, bytes: Data)] = []
        for i in 0..<u16(4) {
            let record = 12 + 16 * i
            let offset = u32(record + 8)
            tables.append((String(decoding: data[record..<record + 4], as: UTF8.self), data[offset..<offset + u32(record + 12)]))
        }

        func put16(_ value: Int, _ target: inout Data) { target.append(contentsOf: [UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]) }
        func put32(_ value: UInt32, _ target: inout Data) { for shift: UInt32 in [24, 16, 8, 0] { target.append(UInt8(value >> shift & 0xFF)) } }

        // A name table with the family, style, full and PostScript names,
        // for the Mac and Windows platforms.
        let postScript = postScriptName(of: family)
        let names: [(Int, String)] = [(1, family), (2, "Regular"), (3, postScript), (4, family), (6, postScript)]
        var records = Data(), storage = Data()
        for (platform, encoding, language) in [(1, 0, 0), (3, 1, 0x409)] {
            for (id, text) in names {
                let bytes = platform == 3 ? Data(text.utf16.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] }) : Data(text.utf8)
                for value in [platform, encoding, language, id, bytes.count, storage.count] { put16(value, &records) }
                storage.append(bytes)
            }
        }
        var name = Data()
        put16(0, &name)
        put16(records.count / 12, &name)
        put16(6 + records.count, &name)
        name.append(records)
        name.append(storage)
        tables = tables.map { $0.tag == "name" ? ("name", name) : $0 }

        func checksum(_ bytes: Data) -> UInt32 {
            var padded = [UInt8](bytes)
            while padded.count % 4 != 0 { padded.append(0) }
            return stride(from: 0, to: padded.count, by: 4).reduce(UInt32(0)) { sum, i in
                sum &+ (UInt32(padded[i]) << 24 | UInt32(padded[i + 1]) << 16 | UInt32(padded[i + 2]) << 8 | UInt32(padded[i + 3]))
            }
        }
        var out = Data(data[0..<12])
        var body = Data()
        var offset = 12 + 16 * tables.count
        var headOffset: Int?
        for table in tables {
            var bytes = table.bytes
            if table.tag == "head" {
                // The whole-file checksum adjustment is worked out with it zeroed.
                bytes.replaceSubrange(bytes.startIndex + 8..<bytes.startIndex + 12, with: Data(count: 4))
                headOffset = offset
            }
            out.append(Data(table.tag.utf8))
            put32(checksum(bytes), &out)
            put32(UInt32(offset), &out)
            put32(UInt32(bytes.count), &out)
            while bytes.count % 4 != 0 { bytes.append(0) }
            body.append(bytes)
            offset += bytes.count
        }
        out.append(body)
        if let headOffset {
            var adjustment = Data()
            put32(0xB1B0_AFBA &- checksum(out), &adjustment)
            out.replaceSubrange(headOffset + 8..<headOffset + 12, with: adjustment)
        }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try out.write(to: destination)
    }
}
