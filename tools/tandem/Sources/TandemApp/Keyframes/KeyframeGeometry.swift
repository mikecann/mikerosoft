import CoreGraphics
import Foundation
import TandemCore

/// A keyframe diamond on a clip in the timeline.
struct KeyframeDiamond: Equatable {
    /// Clip-relative.
    var time: Time
    var centre: CGPoint
    /// The parameters with a keyframe at this time that the diamond stands for.
    var parameters: [String]
    /// A gain keyframe, drawn on the volume line at its level.
    var onVolumeLine: Bool
}

/// Where keyframes draw on a clip and which one the pointer is over.
/// Drawing and hit testing both use this, so they always agree.
enum KeyframeGeometry {
    static let size: CGFloat = 8
    static let hitRadius: CGFloat = 6

    /// The row picture keyframes sit on: along the bottom of the clip.
    static func rowY(in rect: CGRect) -> CGFloat {
        rect.maxY - size / 2 - 3
    }

    /// The volume line's height for a gain: −60 dB at the bottom, +6 dB at
    /// the top, 3 points in from each edge.
    static func gainY(_ gainDB: Double, in rect: CGRect) -> CGFloat {
        let clamped = min(max(gainDB, -60), 6)
        return rect.maxY - 3 - CGFloat((clamped + 60) / 66) * (rect.height - 6)
    }

    /// The gain at a height on the volume line, kept to −60 to +6 dB.
    static func gain(atY y: CGFloat, in rect: CGRect) -> Double {
        let fraction = Double((rect.maxY - 3 - y) / max(1, rect.height - 6))
        return min(max(fraction * 66 - 60, -60), 6)
    }

    /// The diamonds for a clip drawn in `rect`: gain keyframes on the
    /// volume line of a sound clip, everything else in the bottom row, one
    /// diamond per time for all the parameters keyed there.
    static func diamonds(for clip: Clip, rect: CGRect, isAudio: Bool, scale: TimelineScale, tolerance: Time) -> [KeyframeDiamond] {
        guard !clip.keyframes.isEmpty else { return [] }
        var result: [KeyframeDiamond] = []
        if isAudio, let gain = clip.keyframes["audio.gainDB"] {
            for keyframe in gain.sorted(by: { $0.time < $1.time }) {
                let centre = CGPoint(x: scale.x(clip.start + keyframe.time), y: gainY(keyframe.value.number ?? 0, in: rect))
                result.append(KeyframeDiamond(time: keyframe.time, centre: centre, parameters: ["audio.gainDB"], onVolumeLine: true))
            }
        }
        let rowParameters = clip.keyframes.keys.filter { isAudio ? ($0.hasPrefix("audio.") && $0 != "audio.gainDB") : $0.hasPrefix("video.") }
        guard !rowParameters.isEmpty else { return result }
        let row = rowY(in: rect)
        for time in KeyframeEdits.times(in: clip, parameters: rowParameters, tolerance: tolerance) {
            let parameters = KeyframeEdits.parameters(in: clip, keyedAt: time, tolerance: tolerance, among: rowParameters)
            result.append(KeyframeDiamond(time: time, centre: CGPoint(x: scale.x(clip.start + time), y: row), parameters: parameters, onVolumeLine: false))
        }
        return result
    }

    /// The diamond under a point, the nearest when they crowd together.
    static func hit(_ point: CGPoint, in diamonds: [KeyframeDiamond], radius: CGFloat = hitRadius) -> KeyframeDiamond? {
        diamonds
            .filter { abs($0.centre.x - point.x) <= radius && abs($0.centre.y - point.y) <= radius }
            .min { hypot($0.centre.x - point.x, $0.centre.y - point.y) < hypot($1.centre.x - point.x, $1.centre.y - point.y) }
    }

    /// The diamond's outline, for drawing.
    static func path(at centre: CGPoint, size: CGFloat = size) -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: centre.x, y: centre.y - size / 2))
        path.addLine(to: CGPoint(x: centre.x + size / 2, y: centre.y))
        path.addLine(to: CGPoint(x: centre.x, y: centre.y + size / 2))
        path.addLine(to: CGPoint(x: centre.x - size / 2, y: centre.y))
        path.closeSubpath()
        return path
    }
}

extension TimelineHitTester {
    /// A keyframe diamond under a point (in lane coordinates), on any clip
    /// in the lane. Checked before clips, since diamonds sit on top of them.
    func keyframe(at point: CGPoint) -> (clipID: String, trackID: String, diamond: KeyframeDiamond)? {
        guard let lane = layout.lane(atY: point.y), let trackID = lane.trackID, let track = project.track(trackID) else { return nil }
        let tolerance = KeyframeEdits.tolerance(project.settings.frameRate)
        let radius = KeyframeGeometry.hitRadius
        var best: (clipID: String, diamond: KeyframeDiamond, distance: CGFloat)?
        for clip in track.clips where !clip.keyframes.isEmpty {
            let rect = rect(of: clip, in: lane)
            guard point.x >= rect.minX - radius, point.x <= rect.maxX + radius else { continue }
            let diamonds = KeyframeGeometry.diamonds(for: clip, rect: rect, isAudio: lane.kind == .audio, scale: scale, tolerance: tolerance)
            guard let diamond = KeyframeGeometry.hit(point, in: diamonds) else { continue }
            let distance = hypot(diamond.centre.x - point.x, diamond.centre.y - point.y)
            if best == nil || distance < best!.distance { best = (clip.id, diamond, distance) }
        }
        return best.map { ($0.clipID, trackID, $0.diamond) }
    }
}
