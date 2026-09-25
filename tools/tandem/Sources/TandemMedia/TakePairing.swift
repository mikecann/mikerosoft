import AVFoundation
import Foundation
import TandemCore

/// The optional sidecar record-it can write next to a take, so the files
/// line up exactly instead of to the nearest second of their creation dates.
///
/// `<base>.take.json`, beside `<base>-camera.mov` and `<base>-screen.mov`:
///
///     {
///       "version": 1,
///       "files": [
///         { "role": "camera", "file": "main-camera.mov", "startHostTime": 81234.512 },
///         { "role": "screen", "file": "main-screen.mov", "startHostTime": 81234.498 }
///       ]
///     }
///
/// `startHostTime` is the host clock time in seconds (CMClockGetHostTimeClock)
/// of the file's first sample. `file` is optional and defaults to
/// `<base>-<role>.mov`. Offsets are measured from the earliest file.
public struct TakeSidecar: Codable, Equatable, Sendable {
    public struct File: Codable, Equatable, Sendable {
        public var role: String
        public var file: String?
        public var startHostTime: Double

        public init(role: String, file: String? = nil, startHostTime: Double) {
            self.role = role
            self.file = file
            self.startHostTime = startHostTime
        }
    }

    public var version: Int
    public var files: [File]

    public init(version: Int = 1, files: [File]) {
        self.version = version
        self.files = files
    }

    /// The sidecar's file name for a take base name.
    public static func fileName(forBase base: String) -> String { "\(base).take.json" }
}

/// Pairs record-it takes: `<base>-camera.<ext>` with `<base>-screen.<ext>`
/// in the same folder.
enum TakePairing {
    /// Roles record-it writes into file names.
    static let roles = ["camera", "screen"]
    /// Offsets past this are treated as bad data.
    static let maximumOffset = 30.0

    struct Result {
        var notes: [String] = []
    }

    /// The take base name and role for a record-it file name, for example
    /// `("main", "camera")` for `edit/main-camera.mov`.
    static func takeName(forPath path: String) -> (folder: String, base: String, role: String)? {
        let name = (path as NSString).lastPathComponent
        let stem = (name as NSString).deletingPathExtension
        for role in roles {
            let suffix = "-\(role)"
            if stem.lowercased().hasSuffix(suffix), stem.count > suffix.count {
                return ((path as NSString).deletingLastPathComponent, String(stem.dropLast(suffix.count)), role)
            }
        }
        return nil
    }

    /// Sets `takeID` and `takeOffset` on paired files in `items` (which
    /// lines up with `probed`). Files named like a take but without a
    /// partner lose any take they had; other files are left alone.
    static func pair(items: inout [MediaItem], probed: [ProbedFile], folder: ProjectFolder) async -> Result {
        var result = Result()
        var groups: [String: [Int]] = [:]
        var names: [String: (folder: String, base: String)] = [:]
        for (index, item) in items.enumerated() where item.kind == .video {
            guard let take = takeName(forPath: item.path) else { continue }
            let key = "\(take.folder)/\(take.base)".lowercased()
            groups[key, default: []].append(index)
            names[key] = (take.folder, take.base)
        }

        for (key, indices) in groups.sorted(by: { $0.key < $1.key }) {
            guard indices.count >= 2, let name = names[key] else {
                for index in indices {
                    items[index].takeID = nil
                    items[index].takeOffset = nil
                }
                continue
            }
            let takeID = indices.compactMap { items[$0].takeID }.first ?? IDs.make("take")
            let label = name.folder.isEmpty ? name.base : "\(name.folder)/\(name.base)"

            let sidecarURL = folder.url(forPath: name.folder.isEmpty ? TakeSidecar.fileName(forBase: name.base) : "\(name.folder)/\(TakeSidecar.fileName(forBase: name.base))")
            var offsets: [Int: Double]
            if let sidecar = loadSidecar(sidecarURL) {
                offsets = sidecarOffsets(sidecar, base: name.base, items: items, indices: indices, label: label, notes: &result.notes)
            } else {
                offsets = await creationDateOffsets(items: items, probed: probed, indices: indices, folder: folder, label: label, notes: &result.notes)
            }
            for index in indices {
                items[index].takeID = takeID
                items[index].takeOffset = Time(seconds: offsets[index] ?? 0)
            }
        }
        return result
    }

    static func loadSidecar(_ url: URL) -> TakeSidecar? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(TakeSidecar.self, from: data)
    }

    static func sidecarOffsets(_ sidecar: TakeSidecar, base: String, items: [MediaItem], indices: [Int], label: String, notes: inout [String]) -> [Int: Double] {
        var starts: [Int: Double] = [:]
        for index in indices {
            let name = (items[index].path as NSString).lastPathComponent.lowercased()
            let role = takeName(forPath: items[index].path)?.role
            let entry = sidecar.files.first { ($0.file ?? "\(base)-\($0.role).mov").lowercased() == name }
                ?? sidecar.files.first { $0.role.lowercased() == role }
            if let entry, entry.startHostTime.isFinite { starts[index] = entry.startHostTime }
        }
        guard let earliest = starts.values.min() else {
            notes.append("Take \(label): \(TakeSidecar.fileName(forBase: base)) doesn't list these files, so they start together.")
            return [:]
        }
        var offsets: [Int: Double] = [:]
        for (index, start) in starts {
            offsets[index] = clamp(start - earliest, limit: maximumOffset, duration: items[index].duration, file: items[index].path, label: label, notes: &notes)
        }
        return offsets
    }

    static func creationDateOffsets(items: [MediaItem], probed: [ProbedFile], indices: [Int], folder: ProjectFolder, label: String, notes: inout [String]) async -> [Int: Double] {
        var dates: [Int: Date] = [:]
        for index in indices {
            if index < probed.count, let date = probed[index].creationDate {
                dates[index] = date
            } else if let date = await creationDate(of: folder.url(for: items[index])) {
                dates[index] = date
            }
        }
        guard dates.count == indices.count, let earliest = dates.values.min() else {
            notes.append("Take \(label): no creation dates, so its files start together.")
            return [:]
        }
        // QuickTime creation dates usually have whole-second resolution, and
        // record-it starts both files on the same clock tick, so a gap of up
        // to a second between whole-second stamps is rounding, not an offset.
        let wholeSeconds = dates.values.allSatisfy { $0.timeIntervalSince1970.rounded() == $0.timeIntervalSince1970 }
        var offsets: [Int: Double] = [:]
        for (index, date) in dates {
            var offset = date.timeIntervalSince(earliest)
            if wholeSeconds, offset <= 1 { offset = 0 }
            offsets[index] = clamp(offset, limit: maximumOffset, duration: items[index].duration, file: items[index].path, label: label, notes: &notes)
        }
        return offsets
    }

    static func clamp(_ offset: Double, limit: Double, duration: Time?, file: String, label: String, notes: inout [String]) -> Double {
        let tooLong = duration.map { offset >= $0.seconds } ?? false
        guard offset.isFinite, offset >= 0, offset <= limit, !tooLong else {
            notes.append(String(format: "Take %@: %@ would start %.2f s into the take, which can't be right, so it starts with the take.", label, (file as NSString).lastPathComponent, offset))
            return 0
        }
        return offset
    }

    static func creationDate(of url: URL) async -> Date? {
        let asset = AVURLAsset(url: url)
        guard let item = try? await asset.load(.creationDate) else { return nil }
        return try? await item.load(.dateValue)
    }
}
