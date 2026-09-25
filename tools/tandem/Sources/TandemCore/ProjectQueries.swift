import Foundation

/// Where a track lives: `videoTracks[index]` or `audioTracks[index]`.
public struct TrackLocation: Hashable, Sendable {
    public var kind: TrackKind
    public var index: Int

    public init(kind: TrackKind, index: Int) {
        self.kind = kind
        self.index = index
    }
}

extension Project {
    /// Every track, video first (bottom to top), then audio.
    public var trackLocations: [TrackLocation] {
        videoTracks.indices.map { TrackLocation(kind: .video, index: $0) }
            + audioTracks.indices.map { TrackLocation(kind: .audio, index: $0) }
    }

    public subscript(location: TrackLocation) -> Track {
        get { location.kind == .video ? videoTracks[location.index] : audioTracks[location.index] }
        set {
            if location.kind == .video {
                videoTracks[location.index] = newValue
            } else {
                audioTracks[location.index] = newValue
            }
        }
    }

    public func location(ofTrack id: String) -> TrackLocation? {
        if let i = videoTracks.firstIndex(where: { $0.id == id }) { return TrackLocation(kind: .video, index: i) }
        if let i = audioTracks.firstIndex(where: { $0.id == id }) { return TrackLocation(kind: .audio, index: i) }
        return nil
    }

    public func track(_ id: String) -> Track? {
        location(ofTrack: id).map { self[$0] }
    }

    /// Finds a track by name, ignoring case.
    public func track(named name: String, kind: TrackKind? = nil) -> Track? {
        allTracks.first { $0.name.caseInsensitiveCompare(name) == .orderedSame && (kind == nil || $0.kind == kind) }
    }

    public func location(ofClip id: String) -> (track: TrackLocation, index: Int)? {
        for location in trackLocations {
            if let index = self[location].clips.firstIndex(where: { $0.id == id }) {
                return (location, index)
            }
        }
        return nil
    }

    public func clip(_ id: String) -> Clip? {
        location(ofClip: id).map { self[$0.track].clips[$0.index] }
    }

    public func track(containingClip id: String) -> Track? {
        location(ofClip: id).map { self[$0.track] }
    }

    public func media(_ id: String) -> MediaItem? {
        media.first { $0.id == id }
    }

    /// The clip plus every clip sharing its link group, in timeline order.
    public func linkedClipIDs(of id: String) -> [String] {
        guard let clip = clip(id) else { return [] }
        guard let group = clip.linkGroup else { return [id] }
        return allTracks.flatMap(\.clips).filter { $0.linkGroup == group }.map(\.id)
    }

    public func location(ofTransition id: String) -> (track: TrackLocation, index: Int)? {
        for location in trackLocations {
            if let index = self[location].transitions.firstIndex(where: { $0.id == id }) {
                return (location, index)
            }
        }
        return nil
    }

    /// Clips under `time` on every track, bottom video track first.
    public func clips(at time: Time) -> [(track: Track, clip: Clip)] {
        allTracks.compactMap { track in track.clip(at: time).map { (track, $0) } }
    }

    /// How much media a clip can use, or nil when it can't run out (text,
    /// solids, stills, and files that haven't been probed yet).
    public func sourceLimit(for clip: Clip) -> Time? {
        guard let mediaID = clip.mediaID, let item = media(mediaID), item.kind != .image else { return nil }
        return item.duration
    }

    /// Every ID in use, for uniqueness checks.
    public var allIDs: Set<String> {
        var ids = Set<String>()
        ids.insert(id)
        for item in media { ids.insert(item.id) }
        for track in allTracks {
            ids.insert(track.id)
            for clip in track.clips { ids.insert(clip.id) }
            for transition in track.transitions { ids.insert(transition.id) }
        }
        for marker in markers { ids.insert(marker.id) }
        return ids
    }

    /// Clears link groups with only one member left.
    mutating func normalizeLinkGroups() {
        var counts: [String: Int] = [:]
        for clip in allTracks.flatMap(\.clips) {
            if let group = clip.linkGroup { counts[group, default: 0] += 1 }
        }
        guard counts.values.contains(1) else { return }
        for location in trackLocations {
            var track = self[location]
            var changed = false
            for i in track.clips.indices {
                if let group = track.clips[i].linkGroup, counts[group] == 1 {
                    track.clips[i].linkGroup = nil
                    changed = true
                }
            }
            if changed { self[location] = track }
        }
    }
}

extension Track {
    public func index(ofClip id: String) -> Int? {
        clips.firstIndex { $0.id == id }
    }

    /// The clip playing at `time` (start inclusive, end exclusive).
    public func clip(at time: Time) -> Clip? {
        clips.first { $0.start <= time && time < $0.end }
    }

    public func clips(intersecting range: TimeRange) -> [Clip] {
        clips.filter { $0.range.overlaps(range) }
    }

    public func isFree(_ range: TimeRange, ignoring: Set<String> = []) -> Bool {
        !clips.contains { !ignoring.contains($0.id) && $0.range.overlaps(range) }
    }

    /// The clip that ends exactly where `clip` starts.
    public func clip(endingAt time: Time, excluding id: String? = nil) -> Clip? {
        clips.first { $0.end == time && $0.id != id }
    }

    /// The clip that starts exactly at `time`.
    public func clip(startingAt time: Time, excluding id: String? = nil) -> Clip? {
        clips.first { $0.start == time && $0.id != id }
    }

    public var end: Time { clips.map(\.end).max() ?? .zero }
}

extension TimeRange {
    /// Merges overlapping or touching ranges into a sorted list.
    public static func union(_ ranges: [TimeRange]) -> [TimeRange] {
        let sorted = ranges.filter { !$0.isEmpty }.sorted { $0.start < $1.start }
        var result: [TimeRange] = []
        for range in sorted {
            if let last = result.last, range.start <= last.end {
                result[result.count - 1] = TimeRange(start: last.start, end: max(last.end, range.end))
            } else {
                result.append(range)
            }
        }
        return result
    }
}
