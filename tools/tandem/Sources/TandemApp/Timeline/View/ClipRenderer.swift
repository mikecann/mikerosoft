import AppKit
import TandemCore
import TandemMedia

/// How a clip should look this frame.
struct ClipDrawState {
    var selected = false
    /// Shares a link group with a selected clip but isn't selected itself.
    var linked = false
    /// Changed by the drag being previewed.
    var previewed = false
    /// The chosen keyframe's clip-relative time, when it's on this clip.
    var selectedKeyframe: Time?
}

/// Draws clips, transitions and their labels in the Graphite style. Pure
/// drawing: it's handed the geometry and draws into the current context.
@MainActor
struct ClipRenderer {
    let project: Project
    let scale: TimelineScale
    let artwork: MediaArtwork?
    /// The horizontal span being drawn, so detail outside it is skipped.
    let visible: ClosedRange<CGFloat>
    /// Where labels stop when their clip starts further left: the lanes'
    /// left edge, whichever part of them is being drawn.
    let pinX: CGFloat
    /// When set, labels aren't drawn; how far right they'd reach is noted
    /// here instead (see `labelReach`).
    var reach: LabelReach?
    /// The colour space and pixels per point of the screen being drawn
    /// for, so thumbnails come ready to copy (see `MediaArtwork`).
    var colorSpace: CGColorSpace?
    var backingScale: CGFloat = 2

    // MARK: - Styles

    func style(for clip: Clip, lane: TimelineLane) -> Theme.ClipStyle {
        switch lane.style {
        case .music: return Theme.musicClip
        case .sfx: return Theme.sfxClip
        case .voice: return Theme.voiceClip
        default: break
        }
        switch clip.content {
        case .text: return Theme.textClip
        case .graphic: return Theme.graphicClip
        case .solid, .adjustment: return Theme.solidClip
        case .media(let id):
            let role = project.media(id)?.role ?? .other
            if lane.kind == .audio {
                switch role {
                case .music: return Theme.musicClip
                case .sfx, .broll, .sticker, .graphic: return Theme.sfxClip
                default: return Theme.voiceClip
                }
            }
            switch role {
            case .camera: return Theme.cameraClip
            case .screen: return Theme.screenClip
            case .graphic, .sticker: return Theme.graphicClip
            case .music: return Theme.musicClip
            case .sfx: return Theme.sfxClip
            case .broll, .image, .other: return Theme.brollClip
            }
        }
    }

    // MARK: - Clips

    /// The rectangle a clip draws in: one point of gap between touching
    /// clips, so cuts read clearly, on whole points.
    nonisolated static func drawnRect(_ fullRect: CGRect) -> CGRect {
        let inset = fullRect.insetBy(dx: 1, dy: 0)
        guard !inset.isNull else { return inset }
        // Frame times often land exactly on whole points; rounding error
        // either side of one mustn't move an edge a point, or different
        // paintings of the same clip disagree.
        func settled(_ x: CGFloat) -> CGFloat { (x * 1_000_000).rounded() / 1_000_000 }
        let minX = settled(inset.minX)
        return CGRect(x: minX, y: inset.minY, width: settled(inset.maxX) - minX, height: inset.height).integral
    }

    func draw(_ clip: Clip, lane: TimelineLane, rect fullRect: CGRect, state: ClipDrawState, in context: CGContext) {
        let rect = Self.drawnRect(fullRect)
        guard rect.width >= 1, rect.maxX >= visible.lowerBound - 2, rect.minX <= visible.upperBound + 2 else { return }
        let style = style(for: clip, lane: lane)
        // Slivers on a zoomed-out timeline: a plain bar is all that shows,
        // and skipping the paths keeps hundreds of them cheap to draw.
        if rect.width < 6 && !state.selected && !state.previewed {
            context.setFillColor((clip.enabled ? style.border : style.border.opacity(0.4)).cg)
            context.fill(rect)
            return
        }
        let radius = min(Theme.Metrics.clipCornerRadius, rect.width / 2, rect.height / 2)
        let shape = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        let muted = clip.audio?.muted == true && lane.kind == .audio
        context.saveGState()
        if !clip.enabled || muted { context.setAlpha(0.4) }

        context.addPath(shape)
        context.setFillColor(style.fill.cg)
        context.fillPath()
        // Detail clips to the plain rectangle: a rounded clip path costs a
        // mask per clip, which adds up to milliseconds on long timelines.
        context.saveGState()
        context.clip(to: rect.insetBy(dx: 1, dy: 1))
        switch lane.style {
        case .video, .broll:
            drawPictureDetail(clip, rect: rect, style: style, in: context)
        case .voice, .music, .sfx, .audio:
            // Sound effects too: the shape shows where a whoosh peaks.
            drawWaveform(clip, rect: rect, style: style, in: context)
            if lane.style == .music || clip.audio?.fadeIn ?? .zero > .zero || clip.audio?.fadeOut ?? .zero > .zero || clip.keyframes["audio.gainDB"] != nil {
                drawVolumeLine(clip, rect: rect, in: context)
            }
        case .graphics:
            drawGraphicThumbnail(clip, rect: rect, in: context)
        case .text, .transcript:
            break
        }
        drawZoomBands(clip, lane: lane, rect: rect, in: context)
        context.restoreGState()

        // Border.
        let hasBorder = ![LaneStyle.voice, .music, .audio].contains(lane.style)
        if hasBorder {
            context.addPath(CGPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.setStrokeColor(style.border.cg)
            context.setLineWidth(1)
            context.strokePath()
        }
        drawLabel(clip, lane: lane, rect: rect, style: style, in: context)
        context.restoreGState()

        drawKeyframes(clip, lane: lane, rect: rect, state: state, in: context)

        if state.selected || state.previewed {
            let inset = rect.insetBy(dx: 1, dy: 1)
            context.addPath(CGPath(roundedRect: inset, cornerWidth: max(radius - 1, 0), cornerHeight: max(radius - 1, 0), transform: nil))
            context.setStrokeColor(Theme.amber.cg)
            context.setLineWidth(2)
            context.strokePath()
        } else if state.linked {
            context.saveGState()
            context.addPath(CGPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.setStrokeColor(Theme.linkHighlight.cg)
            context.setLineWidth(1)
            context.setLineDash(phase: 0, lengths: [3, 2])
            context.strokePath()
            context.restoreGState()
        }
    }

    /// Thumbnails when the analysis has them, otherwise a quiet film strip
    /// so the clip still reads as picture.
    private func drawPictureDetail(_ clip: Clip, rect: CGRect, style: Theme.ClipStyle, in context: CGContext) {
        let item = clip.mediaID.flatMap { project.media($0) }
        let aspect: CGFloat = {
            guard let item, let w = item.width, let h = item.height, w > 0, h > 0 else { return 16.0 / 9.0 }
            return CGFloat(w) / CGFloat(h)
        }()
        let tileWidth = max(24, rect.height * aspect)
        let start = max(rect.minX, visible.lowerBound - tileWidth)
        let end = min(rect.maxX, visible.upperBound + tileWidth)
        guard start < end else { return }
        // Align tiles to the clip's start so they don't swim while scrolling.
        var x = rect.minX + (((start - rect.minX) / tileWidth).rounded(.down)) * tileWidth
        let hasThumbnails = item.flatMap { artwork?.thumbnailStrip(for: $0) } != nil
        while x < end {
            let tile = CGRect(x: x, y: rect.minY, width: tileWidth, height: rect.height)
            if hasThumbnails, let item {
                let time = scale.time(atX: min(max(x + tileWidth / 2, rect.minX), rect.maxX), rate: project.settings.frameRate)
                let pixels = CGSize(width: tile.width * backingScale, height: tile.height * backingScale)
                if let cg = artwork?.thumbnail(for: item, at: clip.sourceTime(atTimelineTime: time), pixelSize: pixels, colorSpace: colorSpace) {
                    context.saveGState()
                    context.interpolationQuality = .medium
                    context.translateBy(x: tile.minX, y: tile.maxY)
                    context.scaleBy(x: 1, y: -1)
                    context.draw(cg, in: CGRect(origin: .zero, size: tile.size))
                    context.restoreGState()
                } else {
                    // Still decoding: the placeholder frame for a moment.
                    context.setFillColor(style.detail.opacity(0.35).cg)
                    context.fill(tile.insetBy(dx: 1, dy: 3))
                }
            } else {
                // Placeholder frame: a faint panel with a lighter band where a
                // thumbnail's subject would sit.
                context.setFillColor(style.detail.opacity(0.35).cg)
                context.fill(tile.insetBy(dx: 1, dy: 3))
                context.setFillColor(Theme.window.opacity(0.35).cg)
                context.fill(CGRect(x: tile.maxX - 1, y: tile.minY, width: 1, height: tile.height))
            }
            x += tileWidth
        }
    }

    private func drawGraphicThumbnail(_ clip: Clip, rect: CGRect, in context: CGContext) {
        let width = min(rect.height * 16 / 9, rect.width / 2)
        guard width > 12, let item = clip.mediaID.flatMap({ project.media($0) }),
              let cg = artwork?.thumbnail(for: item, at: clip.sourceStart, pixelSize: CGSize(width: width * backingScale, height: rect.height * backingScale), colorSpace: colorSpace) else { return }
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: rect.height))
        context.restoreGState()
    }

    /// Peaks from the analysis, or a flat centre line until they exist.
    private func drawWaveform(_ clip: Clip, rect: CGRect, style: Theme.ClipStyle, in context: CGContext) {
        let midY = rect.midY
        let item = clip.mediaID.flatMap { project.media($0) }
        guard let item, let waveform = artwork?.waveform(for: item), waveform.samplesPerSecond > 0 else {
            context.setFillColor(style.detail.opacity(0.35).cg)
            context.fill(CGRect(x: rect.minX + 2, y: midY - 0.5, width: max(0, rect.width - 4), height: 1))
            return
        }
        // Columns sit on whole points from the clip's start, so a part
        // drawn on its own lines up with what's around it.
        let start = rect.minX + max(0, (visible.lowerBound - rect.minX).rounded(.down))
        let end = min(rect.maxX, visible.upperBound)
        guard start < end else { return }
        let half = rect.height / 2 - 3
        let step: CGFloat = 1
        let path = CGMutablePath()
        let rate = Double(waveform.samplesPerSecond)
        let gain = pow(10, (clip.audio?.gainDB ?? 0) / 20)
        var x = start
        while x < end {
            let t0 = clip.sourceTime(atTimelineTime: Time(seconds: scale.seconds(atX: x)))
            let t1 = clip.sourceTime(atTimelineTime: Time(seconds: scale.seconds(atX: x + step)))
            let lower = max(0, Int((min(t0, t1).seconds * rate).rounded(.down)))
            let upper = min(waveform.peaks.count, max(lower + 1, Int((max(t0, t1).seconds * rate).rounded(.up))))
            var peak: Float = 0
            if lower < upper {
                for index in lower..<upper where waveform.peaks[index] > peak { peak = waveform.peaks[index] }
            }
            let height = max(0.5, CGFloat(min(1, Double(peak) * max(gain, 0.25))) * half)
            path.move(to: CGPoint(x: x + 0.5, y: midY - height))
            path.addLine(to: CGPoint(x: x + 0.5, y: midY + height))
            x += step
        }
        context.addPath(path)
        context.setStrokeColor(style.detail.opacity(0.9).cg)
        context.setLineWidth(1)
        context.strokePath()
    }

    /// The clip's level with its fades, like Filmora's volume line. With
    /// gain keyframes it follows the animated level.
    private func drawVolumeLine(_ clip: Clip, rect: CGRect, in context: CGContext) {
        let audio = clip.audio ?? AudioProperties()
        let bottom = rect.maxY - 2
        let fadeIn = min(scale.width(of: audio.fadeIn), rect.width / 2)
        let fadeOut = min(scale.width(of: audio.fadeOut), rect.width / 2)
        let path = CGMutablePath()
        if let keys = clip.keyframes["audio.gainDB"], !keys.isEmpty {
            // Every 3 points from the clip's start, wherever drawing starts.
            let start = rect.minX + max(0, ((visible.lowerBound - 3 - rect.minX) / 3).rounded(.down) * 3)
            let end = min(rect.maxX, visible.upperBound + 3)
            guard start < end else { return }
            var x = start
            var first = true
            while true {
                let clipTime = Time(seconds: scale.seconds(atX: x)) - clip.start
                var y = KeyframeGeometry.gainY(keys.value(at: clipTime)?.number ?? audio.gainDB, in: rect)
                // Fades pull the line down to silence at the ends.
                if fadeIn > 0, x - rect.minX < fadeIn { y = bottom + (y - bottom) * (x - rect.minX) / fadeIn }
                if fadeOut > 0, rect.maxX - x < fadeOut { y = bottom + (y - bottom) * (rect.maxX - x) / fadeOut }
                if first { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
                first = false
                if x >= end { break }
                x = min(end, x + 3)
            }
        } else {
            let level = KeyframeGeometry.gainY(audio.gainDB, in: rect)
            path.move(to: CGPoint(x: rect.minX, y: fadeIn > 0 ? bottom : level))
            path.addLine(to: CGPoint(x: rect.minX + fadeIn, y: level))
            path.addLine(to: CGPoint(x: rect.maxX - fadeOut, y: level))
            path.addLine(to: CGPoint(x: rect.maxX, y: fadeOut > 0 ? bottom : level))
        }
        context.addPath(path)
        context.setStrokeColor(Theme.text.opacity(0.7).cg)
        context.setLineWidth(1.2)
        context.strokePath()
    }

    /// Zoomed stretches of a screen recording as an amber band, like the
    /// design's "Zoom 150%".
    private func drawZoomBands(_ clip: Clip, lane: TimelineLane, rect: CGRect, in context: CGContext) {
        guard lane.kind == .video, let scales = clip.keyframes["video.transform.scale"], scales.count >= 2 else { return }
        var bandStart: Time?
        for frame in scales.sorted(by: { $0.time < $1.time }) {
            let value = frame.value.number ?? 1
            if value > 1.001, bandStart == nil { bandStart = frame.time }
            if value <= 1.001, let begin = bandStart {
                drawZoomBand(from: begin, to: frame.time, clip: clip, rect: rect, in: context)
                bandStart = nil
            }
        }
        if let begin = bandStart {
            drawZoomBand(from: begin, to: clip.duration, clip: clip, rect: rect, in: context)
        }
    }

    /// Keyframes as amber diamonds: gain on the volume line, everything
    /// else along the bottom. Bigger on selected clips; the chosen one is
    /// white.
    private func drawKeyframes(_ clip: Clip, lane: TimelineLane, rect: CGRect, state: ClipDrawState, in context: CGContext) {
        guard !clip.keyframes.isEmpty, rect.width >= 8 else { return }
        let tolerance = KeyframeEdits.tolerance(project.settings.frameRate)
        let diamonds = KeyframeGeometry.diamonds(for: clip, rect: rect, isAudio: lane.kind == .audio, scale: scale, tolerance: tolerance)
        let size = state.selected ? KeyframeGeometry.size : KeyframeGeometry.size - 2
        for diamond in diamonds where diamond.centre.x >= rect.minX - 5 && diamond.centre.x <= rect.maxX + 5
            && diamond.centre.x >= visible.lowerBound - 6 && diamond.centre.x <= visible.upperBound + 6 {
            let chosen = state.selectedKeyframe.map { abs(($0 - diamond.time).flicks) <= tolerance.flicks } ?? false
            let path = KeyframeGeometry.path(at: diamond.centre, size: chosen ? size + 2 : size)
            context.addPath(path)
            context.setFillColor((chosen ? Theme.text : (state.selected ? Theme.amber : Theme.amber.opacity(0.75))).cg)
            context.fillPath()
            context.addPath(path)
            context.setStrokeColor(Theme.window.opacity(chosen ? 0.9 : 0.6).cg)
            context.setLineWidth(1)
            context.strokePath()
        }
    }

    private func drawZoomBand(from start: Time, to end: Time, clip: Clip, rect: CGRect, in context: CGContext) {
        let x0 = max(rect.minX, scale.x(clip.start + start))
        let x1 = min(rect.maxX, scale.x(clip.start + end))
        guard x1 > x0 else { return }
        let band = CGRect(x: x0, y: rect.minY, width: x1 - x0, height: rect.height)
        context.setFillColor(Theme.amber.opacity(0.1).cg)
        context.fill(band)
        context.setFillColor(Theme.amber.opacity(0.6).cg)
        context.fill(CGRect(x: band.minX, y: band.minY, width: 1, height: band.height))
        context.fill(CGRect(x: band.maxX - 1, y: band.minY, width: 1, height: band.height))
        let peak = clip.keyframes["video.transform.scale"]?.compactMap { $0.value.number }.max() ?? 1
        drawBadge("Zoom \(Int((peak * 100).rounded()))%", at: CGPoint(x: band.minX + 6, y: rect.minY + 4), color: Theme.amber, in: rect, context: context)
    }

    // MARK: - Labels

    /// The layout badge ("PiP right · cutout") for a video clip, if any.
    func badgeText(for clip: Clip) -> String? {
        guard let video = clip.video else { return nil }
        var parts: [String] = []
        if let preset = video.layoutPreset.flatMap(LayoutPreset.init(rawValue:)) {
            switch preset {
            case .full: parts.append("Full")
            case .pipRight: parts.append("PiP ↘")
            case .pipLeft: parts.append("PiP ↙")
            case .split: parts.append("Split")
            case .fill: parts.append("Fill")
            }
        } else if video.transform.scale > 1.001, clip.keyframes["video.transform.scale"] == nil {
            parts.append("Zoom \(Int((video.transform.scale * 100).rounded()))%")
        }
        if video.cutout?.enabled == true { parts.append("cutout") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    func name(of clip: Clip) -> String {
        Self.name(of: clip, in: project)
    }

    /// A clip's name as the timeline shows it: its text, its own name, or
    /// its file's.
    static func name(of clip: Clip, in project: Project) -> String {
        switch clip.content {
        case .text(let text):
            return text.text.split(separator: "\n").first.map(String.init) ?? "Text"
        case .graphic(let graphic):
            // A section card goes by its number and title: "01 Methodology".
            if graphic.template == SectionCard.template, let card = SectionCard.props(of: clip) { return card.label }
            return clip.name ?? graphic.template
        case .solid:
            return clip.name ?? "Solid"
        case .adjustment:
            return clip.name ?? "Adjustment"
        case .media(let id):
            let item = project.media(id)
            if let name = clip.name, !name.isEmpty {
                // Placed clips are named after their file; a library
                // copy's code isn't worth showing.
                if let item, name == (((item.path as NSString).lastPathComponent as NSString).deletingPathExtension) {
                    return TextMetrics.baseName(item.path)
                }
                return name
            }
            return item.map { TextMetrics.baseName($0.path) } ?? "Missing media"
        }
    }

    /// How far right a clip's label reaches (its right edge, or the edge
    /// of its text when truncated), or nil when it has none showing.
    func labelReach(of clip: Clip, lane: TimelineLane, rect fullRect: CGRect) -> CGFloat? {
        var measuring = self
        let reach = LabelReach()
        measuring.reach = reach
        measuring.drawLabel(clip, lane: lane, rect: Self.drawnRect(fullRect), style: style(for: clip, lane: lane), in: nil)
        return reach.maxX.isFinite ? reach.maxX : nil
    }

    /// Draws a clip's name and badges, or with `reach` set, only measures
    /// them (with no context).
    private func drawLabel(_ clip: Clip, lane: TimelineLane, rect: CGRect, style: Theme.ClipStyle, in context: CGContext?) {
        let left = max(rect.minX, pinX)
        let room = rect.maxX - left
        guard room > 14 else { return }
        switch lane.style {
        case .video, .broll:
            var x = left + 4
            if let badge = badgeText(for: clip) {
                x = drawBadge(badge, at: CGPoint(x: x, y: rect.minY + 4), color: Theme.text, in: rect, context: context) + 5
            }
            let role = clip.mediaID.flatMap { project.media($0)?.role }
            // Take clips with a layout badge read from their track, as in
            // the design; everything else is named.
            let isTake = role == .camera || role == .screen
            let quiet = badgeText(for: clip) != nil || clip.keyframes["video.transform.scale"] != nil
            if !(isTake && quiet) {
                // Names sit in a badge like the layout labels, which reads on
                // any thumbnail without the cost of a text shadow.
                drawBadge(name(of: clip), at: CGPoint(x: x, y: rect.minY + 4), color: Theme.textSecondary, in: rect, context: context)
            }
        case .text:
            drawText(name(of: clip), at: CGPoint(x: left + 6, y: rect.midY - 7), maxX: rect.maxX - 4, font: Theme.Fonts.ui(10.5), color: style.label)
        case .graphics:
            var x = left + 8
            if room > 30 {
                drawBars(at: CGPoint(x: x, y: rect.midY - 5), color: style.label, in: context)
                x += 18
            }
            drawText(name(of: clip), at: CGPoint(x: x, y: rect.midY - 7), maxX: rect.maxX - 4, font: Theme.Fonts.ui(10.5), color: style.label)
        case .music:
            var text = name(of: clip)
            if let levels = clip.keyframes["audio.gainDB"]?.compactMap(\.value.number), let low = levels.min(), let high = levels.max() {
                // Animated: the range it moves through.
                let range = low == high ? String(format: "%.0f dB", low) : String(format: "%.0f to %.0f dB", low, high)
                text += " · " + range.replacingOccurrences(of: "-", with: "−")
            } else if let gain = clip.audio?.gainDB, gain != 0 {
                text += " · " + String(format: "%.0f dB", gain).replacingOccurrences(of: "-", with: "−")
            }
            drawText(text, at: CGPoint(x: left + 8, y: rect.minY + 3), maxX: rect.maxX - 4, font: Theme.Fonts.ui(10, .medium), color: style.label)
        case .sfx:
            let font = Theme.Fonts.ui(9.5)
            let text = name(of: clip)
            guard rect.width >= 20 else { return }
            if rect.height >= 28 {
                // Tall enough for the waveform to read: the name sits at
                // the top, like music's, off the middle where it peaks.
                drawText(text, at: CGPoint(x: left + 6, y: rect.minY + 2), maxX: rect.maxX - 4, font: Theme.Fonts.ui(9.5, .medium), color: style.label)
            } else {
                let width = TextMetrics.width(of: text, font: font)
                let x = rect.width > width + 8 ? rect.midX - width / 2 : left + 4
                drawText(text, at: CGPoint(x: x, y: rect.midY - 6), maxX: rect.maxX - 3, font: font, color: style.label)
            }
        case .voice, .audio:
            // Take sound reads from its track, like the design.
            let role = clip.mediaID.flatMap { project.media($0)?.role }
            if rect.height >= 30 && role != .camera && role != .screen {
                drawText(name(of: clip), at: CGPoint(x: left + 6, y: rect.minY + 2), maxX: rect.maxX - 4, font: Theme.Fonts.ui(9.5, .medium), color: style.label.opacity(0.8))
            }
        case .transcript:
            break
        }
    }

    /// Draws a dark rounded badge and returns its right edge.
    @discardableResult
    func drawBadge(_ text: String, at origin: CGPoint, color: Swatch, in clipRect: CGRect, context: CGContext?) -> CGFloat {
        let font = Theme.Fonts.ui(9.5, .semibold)
        guard clipRect.maxX - origin.x > 30 else { return origin.x }
        let size = CGSize(width: TextMetrics.width(of: text, font: font), height: 12)
        // A badge that doesn't fit whole ("Pi") is noise; leave it out.
        guard size.width + 10 <= clipRect.maxX - origin.x - 3 else { return origin.x }
        let badge = CGRect(x: origin.x, y: origin.y, width: size.width + 10, height: 14)
        if let reach {
            reach.note(badge.maxX)
            return badge.maxX
        }
        guard let context else { return badge.maxX }
        context.addPath(CGPath(roundedRect: badge, cornerWidth: 3, cornerHeight: 3, transform: nil))
        context.setFillColor(Theme.badge.cg)
        context.fillPath()
        drawText(text, at: CGPoint(x: badge.minX + 5, y: badge.minY + 0.5), maxX: badge.maxX - 3, font: font, color: color)
        return badge.maxX
    }

    func drawText(_ text: String, at point: CGPoint, maxX: CGFloat, font: NSFont, color: Swatch, shadow: Bool = false) {
        let width = maxX - point.x
        // Truncated to a letter or two ("m…") it only adds clutter, but
        // short text that fits ("Full") always draws.
        guard width > 6 else { return }
        if width < 40, TextMetrics.width(of: text, font: font) > width { return }
        if let reach {
            reach.note(point.x + min(TextMetrics.width(of: text, font: font), width))
            return
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color.ns, .paragraphStyle: paragraph]
        if shadow {
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.8)
            shadow.shadowBlurRadius = 2
            shadow.shadowOffset = .zero
            attributes[.shadow] = shadow
        }
        (text as NSString).draw(with: CGRect(x: point.x, y: point.y, width: width, height: font.pointSize + 5), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attributes)
    }

    private func drawBars(at origin: CGPoint, color: Swatch, in context: CGContext?) {
        if let reach {
            reach.note(origin.x + 12)
            return
        }
        guard let context else { return }
        context.setFillColor(color.cg)
        for (x, y, h) in [(0.0, 5.0, 5.0), (4.5, 2.0, 8.0), (9.0, 0.0, 10.0)] {
            context.fill(CGRect(x: origin.x + x, y: origin.y + y, width: 3, height: h))
        }
    }

    // MARK: - Transitions

    func drawTransition(_ transition: Transition, on track: Track, lane: TimelineLane, selected: Bool, in context: CGContext) {
        guard let band = TransitionGeometry.bandRect(transition, on: track, lane: lane, scale: scale),
              band.maxX >= visible.lowerBound, band.minX <= visible.upperBound else { return }
        let inset = band.insetBy(dx: 0, dy: 1)
        if transition.fromClipID == nil || transition.toClipID == nil {
            // A fade at a clip's head or tail: a ramp across its length.
            let rising = transition.fromClipID == nil
            let ramp = CGMutablePath()
            ramp.move(to: CGPoint(x: inset.minX, y: rising ? inset.maxY : inset.minY))
            ramp.addLine(to: CGPoint(x: inset.maxX, y: rising ? inset.minY : inset.maxY))
            ramp.addLine(to: CGPoint(x: rising ? inset.maxX : inset.minX, y: inset.maxY))
            ramp.closeSubpath()
            context.addPath(ramp)
            context.setFillColor((selected ? Theme.amber.opacity(0.35) : Theme.text.opacity(0.14)).cg)
            context.fillPath()
            context.move(to: CGPoint(x: inset.minX, y: rising ? inset.maxY : inset.minY))
            context.addLine(to: CGPoint(x: inset.maxX, y: rising ? inset.minY : inset.maxY))
            context.setStrokeColor((selected ? Theme.amber : Theme.text.opacity(0.55)).cg)
            context.setLineWidth(1)
            context.strokePath()
            return
        }
        context.setFillColor(Theme.text.opacity(0.1).cg)
        context.fill(inset)
        guard let chip = TransitionGeometry.chipRect(transition, on: track, lane: lane, scale: scale) else { return }
        let radius = min(5, chip.width / 4)
        context.addPath(CGPath(roundedRect: chip, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.setFillColor((selected ? Theme.amber : Theme.transitionChip).cg)
        context.fillPath()
        guard chip.width >= 14 else { return }
        // The bowtie from the design's transition icon.
        let icon = chip.insetBy(dx: chip.width * 0.22, dy: chip.height * 0.28)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: icon.minX, y: icon.minY))
        path.addLine(to: CGPoint(x: icon.midX, y: icon.midY))
        path.addLine(to: CGPoint(x: icon.minX, y: icon.maxY))
        path.closeSubpath()
        path.move(to: CGPoint(x: icon.maxX, y: icon.minY))
        path.addLine(to: CGPoint(x: icon.midX, y: icon.midY))
        path.addLine(to: CGPoint(x: icon.maxX, y: icon.maxY))
        path.closeSubpath()
        context.addPath(path)
        context.setFillColor(Theme.onAmber.cg)
        context.fillPath()
    }
}

/// How far right measured labels reach.
final class LabelReach {
    private(set) var maxX = -CGFloat.infinity

    func note(_ x: CGFloat) {
        maxX = max(maxX, x)
    }
}

/// Cached text widths and file names, so drawing hundreds of clips doesn't
/// lay out the same labels every frame.
@MainActor
enum TextMetrics {
    private static var widths: [String: CGFloat] = [:]
    private static var names: [String: String] = [:]

    static func width(of text: String, font: NSFont) -> CGFloat {
        let key = "\(font.pointSize)|\(font.fontName)|\(text)"
        if let cached = widths[key] { return cached }
        let width = (text as NSString).size(withAttributes: [.font: font]).width
        if widths.count > 4_000 { widths.removeAll() }
        widths[key] = width
        return width
    }

    /// `broll/hf-decider.mp4` to `hf-decider`.
    static func baseName(_ path: String) -> String {
        if let cached = names[path] { return cached }
        let name = MediaCatalog.displayName(forPath: path)
        names[path] = name
        return name
    }
}
