import AppKit
import QuartzCore
import TandemCore

/// Paints the lanes: clips, transitions, the transcript, the in to out
/// range, a drop's target lane. It works in content coordinates, where x is
/// seconds times pixels a second from the start of the timeline and y runs
/// down from the top of the tracks, so the lanes' tiles, their left-edge
/// strip and the full-size canvas used while zooming all paint the same
/// pixels for the same content.
@MainActor
struct LanesPainter {
    /// The project shown (a drag's preview while dragging).
    var project: Project
    var state: TimelineDrawState
    var layout: TimelineLayout
    var artwork: MediaArtwork?
    /// Where labels (and the transcript's phrase) stop when what they name
    /// starts further left: the lanes' left edge. Nil for tiles, which draw
    /// everything where it falls.
    var pinX: CGFloat?
    /// The lanes' right edge, where transcript text stops. Nil for tiles.
    var viewMaxX: CGFloat?
    var phrases: [TranscriptPhrase] = []
    var groups: [Range<Int>] = []
    var highlightedGroup: Int?
    /// Clips a drag or drop moved or made, outlined like selected ones.
    var previewed: Set<String> = []
    var dropLaneID: String?
    /// A keyframe being dragged, drawn at its new time.
    var keyframeDrag: (clipID: String, time: Time)?
    /// The screen's colour space and pixels per point.
    var colorSpace: CGColorSpace?
    var backingScale: CGFloat = 2

    var scale: TimelineScale { TimelineScale(pixelsPerSecond: state.scale.pixelsPerSecond, scrollSeconds: 0) }

    /// Paints what falls in `dirty`. Things that fill the lanes' height
    /// (the in to out range) fill `area`'s.
    func paint(_ dirty: CGRect, area: CGRect, in context: CGContext) {
        let scale = scale
        context.setFillColor(Theme.window.cg)
        context.fill(dirty)

        // In to out.
        if let inPoint = state.inPoint ?? (state.outPoint != nil ? .zero : nil) {
            let end = state.outPoint ?? project.duration
            let x0 = scale.x(inPoint)
            let x1 = scale.x(max(end, inPoint))
            if x1 > x0 {
                context.setFillColor(Theme.inOutFill.cg)
                context.fill(CGRect(x: x0, y: area.minY, width: x1 - x0, height: area.height))
            }
        }

        var renderer = ClipRenderer(project: project, scale: scale, artwork: artwork, visible: dirty.minX...dirty.maxX, pinX: pinX ?? -.infinity)
        renderer.colorSpace = colorSpace
        renderer.backingScale = backingScale
        let selected = state.selection
        let linkedGroups = Set(selected.compactMap { project.clip($0)?.linkGroup })
        for lane in layout.lanes {
            let rect = CGRect(x: dirty.minX, y: lane.y, width: dirty.width, height: lane.height)
            guard rect.intersects(dirty) else { continue }
            if lane.isTranscript {
                paintTranscript(rect: rect, renderer: renderer)
                continue
            }
            guard let trackID = lane.trackID, let track = project.track(trackID) else { continue }
            if dropLaneID == trackID {
                context.setFillColor(Theme.dropTarget.cg)
                context.fill(rect)
            }
            for clip in track.clips {
                let x0 = scale.x(clip.start)
                let x1 = scale.x(clip.end)
                // Keyframe diamonds reach past a clip's ends.
                guard x1 >= dirty.minX - TimelineDamage.keyframeReach, x0 <= dirty.maxX + TimelineDamage.keyframeReach else { continue }
                let clipRect = CGRect(x: x0, y: lane.y, width: max(1, x1 - x0), height: lane.height)
                var drawState = ClipDrawState()
                drawState.selected = selected.contains(clip.id)
                drawState.linked = !drawState.selected && clip.linkGroup.map(linkedGroups.contains) == true
                drawState.previewed = previewed.contains(clip.id) && !drawState.selected
                if let keyframe = state.selectedKeyframe, keyframe.clipID == clip.id {
                    drawState.selectedKeyframe = keyframeDrag?.clipID == clip.id ? keyframeDrag?.time : keyframe.time
                }
                renderer.draw(clip, lane: lane, rect: clipRect, state: drawState, in: context)
            }
            for transition in track.transitions {
                renderer.drawTransition(transition, on: track, lane: lane, selected: state.selectedTransitionID == transition.id, in: context)
            }
            if track.locked {
                paintLockedHatch(rect, in: context)
            } else if track.hidden || (track.kind == .audio && track.muted) {
                context.setFillColor(Theme.window.opacity(0.45).cg)
                context.fill(rect)
            }
        }
    }

    /// Diagonal lines over a locked track, on a grid fixed to the content
    /// so they line up wherever a painting starts.
    private func paintLockedHatch(_ rect: CGRect, in context: CGContext) {
        context.saveGState()
        context.clip(to: rect)
        context.setStrokeColor(Theme.textFaint.opacity(0.18).cg)
        context.setLineWidth(1)
        var x = ((rect.minX - rect.height) / 8).rounded(.down) * 8
        while x < rect.maxX {
            context.move(to: CGPoint(x: x, y: rect.maxY))
            context.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
            x += 8
        }
        context.strokePath()
        context.restoreGState()
    }

    // MARK: - Transcript

    private static let transcriptFont = Theme.Fonts.ui(10.5)

    private func paintTranscript(rect: CGRect, renderer: ClipRenderer) {
        let y = rect.minY + (rect.height - 14) / 2
        if phrases.isEmpty {
            // A note at the lanes' left edge, which tiles leave to the strip.
            guard let pinX else { return }
            renderer.drawText(emptyTranscriptNote, at: CGPoint(x: pinX + 6, y: y), maxX: (viewMaxX ?? .infinity) - 6, font: Self.transcriptFont, color: Theme.textFainter)
            return
        }
        let scale = scale
        for (index, group) in groups.enumerated() {
            let first = phrases[group.lowerBound]
            let x0 = scale.x(first.start)
            let next = index + 1 < groups.count ? scale.x(phrases[groups[index + 1].lowerBound].start) : .infinity
            guard next >= rect.minX, x0 <= rect.maxX else { continue }
            renderer.drawText(
                first.text, at: CGPoint(x: max(x0, pinX ?? -.infinity) + 2, y: y), maxX: min(next - 6, viewMaxX ?? .infinity),
                font: Self.transcriptFont, color: index == highlightedGroup ? Theme.text : Theme.textFaint
            )
        }
    }

    private var emptyTranscriptNote: String {
        let hasTake = project.allTracks.flatMap(\.clips).contains { clip in
            clip.mediaID.flatMap { project.media($0) }.map { $0.role == .camera && $0.hasAudio } ?? false
        }
        return hasTake ? "The transcript shows here once the take is transcribed." : "Place a take to see what's said here."
    }

    // MARK: - The left edge

    /// How far right, in content x, things pinned to the lanes' left edge
    /// reach: the labels of clips that start further left, drawn at the
    /// edge, and the same labels where they'd fall unpinned (tiles draw
    /// those, and the strip has to cover them). `pinX` when nothing is
    /// pinned.
    func pinnedReach() -> CGFloat {
        guard let pinX else { return -.infinity }
        let scale = scale
        var reach = pinX
        let pinned = ClipRenderer(project: project, scale: scale, artwork: nil, visible: pinX...pinX, pinX: pinX)
        let natural = ClipRenderer(project: project, scale: scale, artwork: nil, visible: pinX...pinX, pinX: -.infinity)
        for lane in layout.lanes {
            if lane.isTranscript {
                reach = max(reach, transcriptReach(pinX: pinX))
                continue
            }
            guard let trackID = lane.trackID, let track = project.track(trackID) else { continue }
            // Clips on a track don't overlap and run in time order, so only
            // the last one to start left of the edge can cross it.
            let edge = Time(seconds: Double(pinX) / scale.pixelsPerSecond)
            var low = 0
            var high = track.clips.count
            while low < high {
                let middle = (low + high) / 2
                if track.clips[middle].start < edge { low = middle + 1 } else { high = middle }
            }
            for clip in track.clips[max(0, low - 2)..<low] {
                let x0 = scale.x(clip.start)
                let x1 = scale.x(clip.end)
                guard x0 < pinX, x1 > pinX else { continue }
                let rect = CGRect(x: x0, y: lane.y, width: max(1, x1 - x0), height: lane.height)
                for renderer in [pinned, natural] {
                    if let right = renderer.labelReach(of: clip, lane: lane, rect: rect) { reach = max(reach, right) }
                }
            }
        }
        return reach
    }

    private func transcriptReach(pinX: CGFloat) -> CGFloat {
        let font = Self.transcriptFont
        if phrases.isEmpty {
            return pinX + 6 + TextMetrics.width(of: emptyTranscriptNote, font: font)
        }
        let scale = scale
        // The run whose text starts left of the edge: at most one.
        guard let index = groups.lastIndex(where: { scale.x(phrases[$0.lowerBound].start) < pinX }) else { return pinX }
        let text = phrases[groups[index].lowerBound].text
        let x0 = scale.x(phrases[groups[index].lowerBound].start)
        let next = index + 1 < groups.count ? scale.x(phrases[groups[index + 1].lowerBound].start) : .infinity
        let width = TextMetrics.width(of: text, font: font)
        // Pinned, and where the tiles draw it.
        let pinned = min(pinX + 2 + width, min(next - 6, viewMaxX ?? .infinity))
        let natural = min(x0 + 2 + width, next - 6)
        return max(pinX, pinned, natural)
    }
}

/// A view that shows part of the lanes, painted by `TimelineLanesView`:
/// a tile of the content, the strip along the left edge, or the canvas
/// that shows everything while zooming.
@MainActor
final class LanesPaintView: NSView {
    enum Role: Equatable {
        /// `LaneTiles.width` points of the content, from `index` times that.
        case tile(index: Int)
        case strip
        case canvas
    }

    var role: Role
    weak var lanes: TimelineLanesView?

    init(role: Role, lanes: TimelineLanesView) {
        self.role = role
        self.lanes = lanes
        super.init(frame: .zero)
        wantsLayer = true
        clipsToBounds = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    override var isOpaque: Bool { true }

    /// Clicks and drags belong to the lanes view underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        lanes?.paint(self, dirtyRect)
    }
}
