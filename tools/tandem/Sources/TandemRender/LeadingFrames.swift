import Foundation
import TandemCore

/// Where a file's leading frames are, when the file doesn't say so itself.
///
/// In open-GOP HEVC a keyframe can be a CRA picture: the few frames shown
/// just before it are decoded after it and refer back to the previous GOP.
/// A file marks such keyframes with a `sync` sample group; without it (as
/// after an ffmpeg `-c copy` remux) AVFoundation starts decoding at the
/// keyframe when it seeks into those frames, and they come out missing or
/// as a stale earlier frame. This reads the sample tables to find those
/// windows, so the compositor knows which frames to decode itself.
///
/// Only HEVC video with frame reordering, sync samples and no `sync` group
/// gets a map; everything else seeks fine and gets nil.
struct LeadingFrameMap: Equatable {
    /// Media-time windows [start, end) of leading frames, sorted. `end` is
    /// the keyframe they lead to.
    var windows: [TimeRange]

    /// The window holding a media time, if any.
    func window(containing time: Time) -> TimeRange? {
        var low = 0
        var high = windows.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let w = windows[mid]
            if time < w.start {
                high = mid - 1
            } else if time >= w.end {
                low = mid + 1
            } else {
                return w
            }
        }
        return nil
    }

    // MARK: - Reading the file

    /// Parses a QuickTime or MP4 file's first video track. Nil when the
    /// file seeks fine, or can't be read.
    static func read(_ url: URL) -> LeadingFrameMap? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let moov = topLevelBox("moov", in: handle) else { return nil }
        return parse(moov: moov)
    }

    struct Box {
        var type: String
        /// The payload, after the header.
        var body: Data
    }

    /// Children of a box payload (or of a whole file's worth of data).
    static func boxes(in data: Data) -> [Box] {
        var result: [Box] = []
        var position = data.startIndex
        while position + 8 <= data.endIndex {
            var size = Int(data.readUInt32(at: position))
            let type = String(decoding: data[(position + 4)..<(position + 8)], as: UTF8.self)
            var header = 8
            if size == 1 {
                guard position + 16 <= data.endIndex else { break }
                size = Int(data.readUInt64(at: position + 8))
                header = 16
            } else if size == 0 {
                size = data.endIndex - position
            }
            guard size >= header, position + size <= data.endIndex else { break }
            result.append(Box(type: type, body: data[(position + header)..<(position + size)]))
            position += size
        }
        return result
    }

    /// Finds a top-level box by walking headers, so a large `mdat` is
    /// skipped rather than read.
    static func topLevelBox(_ wanted: String, in handle: FileHandle) -> Data? {
        guard let end = try? handle.seekToEnd() else { return nil }
        var position: UInt64 = 0
        while position + 8 <= end {
            try? handle.seek(toOffset: position)
            guard let header = try? handle.read(upToCount: 16), header.count >= 8 else { return nil }
            var size = UInt64(header.readUInt32(at: header.startIndex))
            let type = String(decoding: header[(header.startIndex + 4)..<(header.startIndex + 8)], as: UTF8.self)
            var headerSize: UInt64 = 8
            if size == 1 {
                guard header.count >= 16 else { return nil }
                size = header.readUInt64(at: header.startIndex + 8)
                headerSize = 16
            } else if size == 0 {
                size = end - position
            }
            guard size >= headerSize else { return nil }
            if type == wanted {
                // Movie boxes are small (under a few MB for hours of video).
                guard size < 256 * 1024 * 1024 else { return nil }
                try? handle.seek(toOffset: position + headerSize)
                return try? handle.read(upToCount: Int(size - headerSize))
            }
            position += size
        }
        return nil
    }

    static func parse(moov: Data) -> LeadingFrameMap? {
        let top = boxes(in: moov)
        let movieTimescale = top.first { $0.type == "mvhd" }.map { mvhd -> UInt32 in
            let version = mvhd.body.first ?? 0
            return mvhd.body.readUInt32(at: mvhd.body.startIndex + (version == 1 ? 20 : 12))
        } ?? 600
        for trak in top where trak.type == "trak" {
            let parts = boxes(in: trak.body)
            guard let mdia = parts.first(where: { $0.type == "mdia" }).map({ boxes(in: $0.body) }),
                  let handler = mdia.first(where: { $0.type == "hdlr" }),
                  handler.body.count >= 12,
                  String(decoding: handler.body[(handler.body.startIndex + 8)..<(handler.body.startIndex + 12)], as: UTF8.self) == "vide" else { continue }
            return parseVideoTrack(trak: parts, mdia: mdia, movieTimescale: movieTimescale)
        }
        return nil
    }

    static func parseVideoTrack(trak: [Box], mdia: [Box], movieTimescale: UInt32) -> LeadingFrameMap? {
        guard let mdhd = mdia.first(where: { $0.type == "mdhd" }),
              let minf = mdia.first(where: { $0.type == "minf" }).map({ boxes(in: $0.body) }),
              let stbl = minf.first(where: { $0.type == "stbl" }).map({ boxes(in: $0.body) }) else { return nil }
        let version = mdhd.body.first ?? 0
        let timescale = Double(mdhd.body.readUInt32(at: mdhd.body.startIndex + (version == 1 ? 20 : 12)))
        guard timescale > 0 else { return nil }
        func table(_ type: String) -> Data? { stbl.first { $0.type == type }?.body }

        // Only open-GOP HEVC that has lost its sync group needs a map.
        guard let stsd = table("stsd"), stsd.count >= 16 else { return nil }
        let codec = String(decoding: stsd[(stsd.startIndex + 12)..<(stsd.startIndex + 16)], as: UTF8.self)
        guard codec == "hvc1" || codec == "hev1" else { return nil }
        if stbl.contains(where: { $0.type == "sgpd" && $0.body.count >= 8 &&
            String(decoding: $0.body[($0.body.startIndex + 4)..<($0.body.startIndex + 8)], as: UTF8.self) == "sync" }) {
            return nil
        }
        guard let stts = table("stts"), let ctts = table("ctts"), let stss = table("stss") else { return nil }

        // Decode times.
        var decode: [Int64] = []
        var clock: Int64 = 0
        let sttsCount = Int(stts.readUInt32(at: stts.startIndex + 4))
        for i in 0..<sttsCount {
            let at = stts.startIndex + 8 + i * 8
            guard at + 8 <= stts.endIndex else { return nil }
            let count = Int(stts.readUInt32(at: at))
            let delta = Int64(stts.readUInt32(at: at + 4))
            for _ in 0..<count {
                decode.append(clock)
                clock += delta
            }
        }
        // Composition offsets (signed, whatever the box version says).
        var offsets: [Int64] = []
        offsets.reserveCapacity(decode.count)
        let cttsCount = Int(ctts.readUInt32(at: ctts.startIndex + 4))
        for i in 0..<cttsCount {
            let at = ctts.startIndex + 8 + i * 8
            guard at + 8 <= ctts.endIndex else { return nil }
            let count = Int(ctts.readUInt32(at: at))
            let offset = Int64(Int32(bitPattern: ctts.readUInt32(at: at + 4)))
            offsets.append(contentsOf: repeatElement(offset, count: count))
        }
        guard offsets.count == decode.count, !decode.isEmpty else { return nil }
        let syncCount = Int(stss.readUInt32(at: stss.startIndex + 4))
        var syncs: [Int] = []
        for i in 0..<syncCount {
            let at = stss.startIndex + 8 + i * 4
            guard at + 4 <= stss.endIndex else { return nil }
            syncs.append(Int(stss.readUInt32(at: at)) - 1)
        }

        // The edit list maps media time onto the track's timeline: an empty
        // edit delays it, and one edit picks where in the media it starts.
        var mediaStart: Int64 = 0
        var delay = 0.0
        if let edts = trak.first(where: { $0.type == "edts" }).map({ boxes(in: $0.body) }),
           let elst = edts.first(where: { $0.type == "elst" })?.body {
            let elstVersion = elst.first ?? 0
            let count = Int(elst.readUInt32(at: elst.startIndex + 4))
            var used = 0
            for i in 0..<count {
                let entrySize = elstVersion == 1 ? 20 : 12
                let at = elst.startIndex + 8 + i * entrySize
                guard at + entrySize <= elst.endIndex else { return nil }
                let duration = elstVersion == 1 ? Double(elst.readUInt64(at: at)) : Double(elst.readUInt32(at: at))
                let mediaTime = elstVersion == 1 ? Int64(bitPattern: elst.readUInt64(at: at + 8)) : Int64(Int32(bitPattern: elst.readUInt32(at: at + 4)))
                if mediaTime == -1 {
                    delay += duration / Double(movieTimescale)
                } else {
                    mediaStart = mediaTime
                    used += 1
                }
            }
            // Several edits would need a real timeline; not worth guessing.
            if used > 1 { return nil }
        }
        func seconds(_ sample: Int) -> Double {
            Double(decode[sample] + offsets[sample] - mediaStart) / timescale + delay
        }

        var windows: [TimeRange] = []
        for (n, key) in syncs.enumerated() where key >= 0 && key < decode.count {
            let next = n + 1 < syncs.count ? min(syncs[n + 1], decode.count) : decode.count
            let keyTime = seconds(key)
            var earliest = keyTime
            if key + 1 < next {
                for sample in (key + 1)..<next {
                    let t = seconds(sample)
                    if t < earliest { earliest = t }
                }
            }
            if earliest < keyTime {
                windows.append(TimeRange(start: Time(seconds: earliest), end: Time(seconds: keyTime)))
            }
        }
        windows.sort { $0.start < $1.start }
        return LeadingFrameMap(windows: windows)
    }
}

/// Leading-frame maps by file, read once per version of the file.
final class LeadingFrameCache: @unchecked Sendable {
    static let shared = LeadingFrameCache()
    private let lock = NSLock()
    private var entries: [String: (stamp: String, map: LeadingFrameMap?)] = [:]

    func map(for url: URL) -> LeadingFrameMap? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let stamp = "\((attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)|\(attributes?[.size] as? Int ?? 0)"
        if let hit = lock.withLock({ entries[url.path] }), hit.stamp == stamp { return hit.map }
        let map = LeadingFrameMap.read(url)
        lock.withLock { entries[url.path] = (stamp, map) }
        return map
    }
}

extension Data {
    func readUInt32(at offset: Index) -> UInt32 {
        guard offset + 4 <= endIndex else { return 0 }
        return self[offset..<(offset + 4)].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
    }

    func readUInt64(at offset: Index) -> UInt64 {
        guard offset + 8 <= endIndex else { return 0 }
        return self[offset..<(offset + 8)].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
    }
}
