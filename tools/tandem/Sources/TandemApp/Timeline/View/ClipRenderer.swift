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
}

/// Draws clips, transitions and their labels in the Graphite style. Pure
/// drawing: it's handed the geometry and draws into the current context.
@MainActor
struct ClipRenderer {
    let project: Project
    let scale: TimelineScale
    let artwork: MediaArtwork?
    /// The lanes' visible horizontal span, so off-screen detail is skipped.
    let visible: ClosedRange<CGFloat>

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

    func draw(_ clip: Clip, lane: TimelineLane, rect fullRect: CGRect, state: ClipDrawState, in context: CGContext) {
        // One point of gap between touching clips, so cuts read clearly.
        let rect = fullRect.insetBy(dx: 1, dy: 0).integral.insetBy(dx: 0, dy: 0)
        guard rect.width >= 1, rect.maxX >= visible.lowerBound - 2, rect.minX <= visible.upperBound + 2 else { return }
        let style = style(for: clip, lane: lane)
        let radius = min(Theme.Metrics.clipCornerRadius, rect.width / 2, rect.height / 2)
        let shape = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        let muted = clip.audio?.muted == true && lane.kind == .audio
        context.saveGState()
        if !clip.enabled || muted { context.setAlpha(0.4) }

        context.saveGState()
        context.addPath(shape)
        context.clip()
        context.setFillColor(style.fill.cg)
        context.fill(rect)
        switch lane.style {
        case .video, .broll:
            drawPictureDetail(clip, rect: rect, style: style, in: context)
        case .voice, .music, .sfx, .audio:
            if lane.style != .sfx { drawWaveform(clip, rect: rect, style: style, in: context) }
            if lane.style == .music || clip.audio?.fadeIn ?? .zero > .zero || clip.audio?.fadeOut ?? .zero > .zero {
                drawVolumeLine(clip, rect: rect, in: context)
            }
        case .graphics:
            drawGraphicThumbnail(clip, rect: rect, in: context)
        case .text, .transcript:
            break
        }
        drawKeyframes(clip, rect: rect, in: context)
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
                if let image = artwork?.thumbnail(for: item, at: clip.sourceTime(atTimelineTime: time)),
                   let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    context.saveGState()
                    context.translateBy(x: tile.minX, y: tile.maxY)
                    context.scaleBy(x: 1, y: -1)
                    context.draw(cg, in: CGRect(origin: .zero, size: tile.size))
                    context.restoreGState()
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
        guard let item = clip.mediaID.flatMap({ project.media($0) }),
              let image = artwork?.thumbnail(for: item, at: clip.sourceStart),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let width = min(rect.height * 16 / 9, rect.width / 2)
        guard width > 12 else { return }
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
        let start = max(rect.minX, visible.lowerBound)
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

    /// The clip's level with its fades, like Filmora's volume line.
    private func drawVolumeLine(_ clip: Clip, rect: CGRect, in context: CGContext) {
        let audio = clip.audio ?? AudioProperties()
        // -60 dB at the bottom, +6 dB at the top.
        let db = min(max(audio.gainDB, -60), 6)
        let level = rect.maxY - 3 - CGFloat((db + 60) / 66) * (rect.height - 6)
        let bottom = rect.maxY - 2
        let fadeIn = min(scale.width(of: audio.fadeIn), rect.width / 2)
        let fadeOut = min(scale.width(of: audio.fadeOut), rect.width / 2)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.minX, y: fadeIn > 0 ? bottom : level))
        path.addLine(to: CGPoint(x: rect.minX + fadeIn, y: level))
        path.addLine(to: CGPoint(x: rect.maxX - fadeOut, y: level))
        path.addLine(to: CGPoint(x: rect.maxX, y: fadeOut > 0 ? bottom : level))
        context.addPath(path)
        context.setStrokeColor(Theme.text.opacity(0.7).cg)
        context.setLineWidth(1.2)
        context.strokePath()
    }

    /// Transform keyframes as amber diamonds along the bottom, and zoomed
    /// stretches as an amber band, like the design's "Zoom 150%".
    private func drawKeyframes(_ clip: Clip, rect: CGRect, in context: CGContext) {
        let keys = clip.keyframes.filter { $0.key.hasPrefix("video.transform") }
        guard !keys.isEmpty else { return }
        let times = Set(keys.values.flatMap { $0.map(\.time) }).sorted()
        // Zoom band: from the first keyframe that zooms in to the next one
        // that returns to 1.
        if let scales = clip.keyframes["video.transform.scale"], scales.count >= 2 {
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
        for time in times {
            let x = scale.x(clip.start + time)
            guard x >= rect.minX - 4, x <= rect.maxX + 4 else { continue }
            let size: CGFloat = 7
            let centre = CGPoint(x: x, y: rect.maxY - size / 2 - 3)
            let diamond = CGMutablePath()
            diamond.move(to: CGPoint(x: centre.x, y: centre.y - size / 2))
            diamond.addLine(to: CGPoint(x: centre.x + size / 2, y: centre.y))
            diamond.addLine(to: CGPoint(x: centre.x, y: centre.y + size / 2))
            diamond.addLine(to: CGPoint(x: centre.x - size / 2, y: centre.y))
            diamond.closeSubpath()
            context.addPath(diamond)
            context.setFillColor(Theme.amber.cg)
            context.fillPath()
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
            }
        } else if video.transform.scale > 1.001, clip.keyframes["video.transform.scale"] == nil {
            parts.append("Zoom \(Int((video.transform.scale * 100).rounded()))%")
        }
        if video.cutout?.enabled == true { parts.append("cutout") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    func name(of clip: Clip) -> String {
        switch clip.content {
        case .text(let text):
            return text.text.split(separator: "\n").first.map(String.init) ?? "Text"
        case .graphic(let graphic):
            return clip.name ?? graphic.template
        case .solid:
            return clip.name ?? "Solid"
        case .adjustment:
            return clip.name ?? "Adjustment"
        case .media(let id):
            if let name = clip.name, !name.isEmpty { return name }
            return project.media(id).map { URL(fileURLWithPath: $0.path).deletingPathExtension().lastPathComponent } ?? "Missing media"
        }
    }

    private func drawLabel(_ clip: Clip, lane: TimelineLane, rect: CGRect, style: Theme.ClipStyle, in context: CGContext) {
        let left = max(rect.minX, visible.lowerBound)
        let room = rect.maxX - left
        guard room > 14 else { return }
        switch lane.style {
        case .video, .broll:
            var x = left + 4
            if let badge = badgeText(for: clip) {
                x = drawBadge(badge, at: CGPoint(x: x, y: rect.minY + 4), color: Theme.text, in: rect, context: context) + 5
            }
            let role = clip.mediaID.flatMap { project.media($0)?.role }
            // Takes read from their track, as in the design; other clips
            // are named.
            if role != .camera && role != .screen {
                drawText(name(of: clip), at: CGPoint(x: x, y: rect.minY + 4), maxX: rect.maxX - 4, font: Theme.Fonts.ui(9.5, .semibold), color: Theme.text, shadow: true)
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
            if let gain = clip.audio?.gainDB, gain != 0 {
                text += " · " + String(format: "%.0f dB", gain).replacingOccurrences(of: "-", with: "−")
            }
            drawText(text, at: CGPoint(x: left + 8, y: rect.minY + 3), maxX: rect.maxX - 4, font: Theme.Fonts.ui(10, .medium), color: style.label)
        case .sfx:
            let font = Theme.Fonts.ui(9.5)
            let text = name(of: clip)
            let width = (text as NSString).size(withAttributes: [.font: font]).width
            let x = rect.width > width + 8 ? rect.midX - width / 2 : left + 4
            drawText(text, at: CGPoint(x: x, y: rect.midY - 6), maxX: rect.maxX - 3, font: font, color: style.label)
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
    func drawBadge(_ text: String, at origin: CGPoint, color: Swatch, in clipRect: CGRect, context: CGContext) -> CGFloat {
        let font = Theme.Fonts.ui(9.5, .semibold)
        let size = (text as NSString).size(withAttributes: [.font: font])
        let badge = CGRect(x: origin.x, y: origin.y, width: min(size.width + 10, clipRect.maxX - origin.x - 3), height: 14)
        guard badge.width > 12 else { return origin.x }
        context.addPath(CGPath(roundedRect: badge, cornerWidth: 3, cornerHeight: 3, transform: nil))
        context.setFillColor(Theme.badge.cg)
        context.fillPath()
        drawText(text, at: CGPoint(x: badge.minX + 5, y: badge.minY + 0.5), maxX: badge.maxX - 3, font: font, color: color)
        return badge.maxX
    }

    func drawText(_ text: String, at point: CGPoint, maxX: CGFloat, font: NSFont, color: Swatch, shadow: Bool = false) {
        let width = maxX - point.x
        guard width > 6 else { return }
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

    private func drawBars(at origin: CGPoint, color: Swatch, in context: CGContext) {
        context.setFillColor(color.cg)
        for (x, y, h) in [(0.0, 5.0, 5.0), (4.5, 2.0, 8.0), (9.0, 0.0, 10.0)] {
            context.fill(CGRect(x: origin.x + x, y: origin.y + y, width: 3, height: h))
        }
    }

    // MARK: - Transitions

    func drawTransition(_ transition: Transition, on track: Track, lane: TimelineLane, selected: Bool, in context: CGContext) {
        guard let band = TransitionGeometry.bandRect(transition, on: track, lane: lane, scale: scale),
              band.maxX >= visible.lowerBound, band.minX <= visible.upperBound else { return }
        context.setFillColor(Theme.text.opacity(0.1).cg)
        context.fill(band.insetBy(dx: 0, dy: 1))
        guard let chip = TransitionGeometry.chipRect(transition, on: track, lane: lane, scale: scale) else { return }
        context.addPath(CGPath(roundedRect: chip, cornerWidth: 5, cornerHeight: 5, transform: nil))
        context.setFillColor((selected ? Theme.amber : Theme.transitionChip).cg)
        context.fillPath()
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
