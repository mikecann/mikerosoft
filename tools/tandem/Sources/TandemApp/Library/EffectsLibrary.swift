import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI
import TandemCore
import TandemMedia
import TandemRender

/// The Effects and Transitions tabs, one panel with two halves as in the
/// design, and looks (LUTs from the asset library) beside them. Effect
/// tiles show the effect on a frame of the selected clip (or the clip
/// under the playhead); transition tiles play the move between the clips
/// either side of the nearest cut as you hover.
struct EffectsLibrary: View {
    let model: EditorModel
    @Binding var showTransitions: Bool
    @State private var search = ""
    @State private var selected: String?

    var body: some View {
        if AssetLibraryHost.shared.looksShown {
            AssetBrowser(model: model, sections: [.looks], section: .constant(.looks), tabs: AnyView(tabs(count: nil)))
        } else {
            builtIn
        }
    }

    private func tabs(count: Int?) -> some View {
        let host = AssetLibraryHost.shared
        return HStack(spacing: 16) {
            SubTab(title: "Effects", icon: Icons.effects, selected: !host.looksShown && !showTransitions) {
                host.looksShown = false
                showTransitions = false
            }
            SubTab(title: "Transitions", icon: Icons.transitions, selected: !host.looksShown && showTransitions) {
                host.looksShown = false
                showTransitions = true
            }
            SubTab(title: "Looks", icon: Icons.looks, selected: host.looksShown) { host.looksShown = true }
            Spacer(minLength: 4)
            if let count {
                Text(verbatim: String(count))
                    .font(.ui(11.5))
                    .foregroundStyle(Theme.textFaint.color)
            }
        }
    }

    private var builtIn: some View {
        let frames = PreviewFrames(model: model)
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                tabs(count: showTransitions ? TransitionType.allCases.count : effects.count)
                SearchField(text: $search, prompt: showTransitions ? "Search transitions" : "Search effects")
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 10)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    LazyVGrid(columns: TileGrid.columns(width: 82), alignment: .leading, spacing: 12) {
                        if showTransitions {
                            ForEach(transitions, id: \.self) { type in
                                LibraryTile(title: type.displayName, selected: selected == type.rawValue, width: 82, height: 48, drag: .transition(type)) {
                                    TransitionPreview(type: type, frames: frames)
                                } select: {
                                    selected = type.rawValue
                                } add: {
                                    addTransition(type)
                                } dragStarted: {
                                    // Its sound comes in from the library as the drag starts.
                                    TransitionSoundActions.prepareForDrop(type, in: model)
                                }
                                .tip(TransitionSoundText.tileTip(type))
                            }
                        } else {
                            ForEach(effects, id: \.type) { definition in
                                LibraryTile(title: definition.name, selected: selected == definition.type, width: 82, height: 48, drag: .effect(definition.type)) {
                                    EffectPreview(definition: definition, frames: frames)
                                } select: {
                                    selected = definition.type
                                } add: {
                                    addEffect(definition)
                                }
                                .tip("\(definition.summary)\nDouble-click for the selected clips, or drag onto a clip.")
                            }
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
            }
            .scrollIndicators(.hidden)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var effects: [EffectDefinition] {
        let order = ["Colour", "Style", "Utility", "Audio"]
        let all = EffectRegistry.standard.sorted.sorted {
            (order.firstIndex(of: $0.category) ?? 9, $0.name) < (order.firstIndex(of: $1.category) ?? 9, $1.name)
        }
        let text = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !text.isEmpty else { return all }
        return all.filter { $0.name.lowercased().contains(text) || $0.category.lowercased().contains(text) || $0.summary.lowercased().contains(text) }
    }

    private var transitions: [TransitionType] {
        let text = search.trimmingCharacters(in: .whitespaces).lowercased()
        return TransitionType.allCases.filter { text.isEmpty || $0.displayName.lowercased().contains(text) }
    }

    private func addTransition(_ type: TransitionType) {
        let track = TimelineEdits.ordered(model.selection, in: model.project).first.flatMap { model.project.track(containingClip: $0)?.id }
        TransitionSoundActions.add(type, at: model.playback.time, trackID: track, anyTrack: true, in: model)
    }

    private func addEffect(_ definition: EffectDefinition) {
        let targets = TimelineEdits.ordered(model.selection, in: model.project)
        let batches = targets.compactMap { LibraryDrops.effect(definition.type, on: $0, in: model.project) }
        guard !batches.isEmpty else {
            model.show(.info, "Select a \(definition.domain == .video ? "video" : "sound") clip to add \(definition.name.lowercased()) to.")
            return
        }
        model.apply(EditBatch(label: batches[0].label, commands: batches.flatMap(\.commands)))
        model.inspectorTab = definition.category == "Colour" ? .colour : (definition.domain == .audio ? .audio : .video)
    }
}

/// The frames the previews use: the picture of the selected video clip or
/// the one under the playhead, and for transitions the clips either side
/// of the nearest cut. Thumbnails from the analysis; nil until they exist.
@MainActor
struct PreviewFrames {
    let current: CGImage?
    let before: CGImage?
    let after: CGImage?
    /// Changes when the frames do, to key cached previews.
    let key: String

    init(model: EditorModel) {
        let project = model.project
        let time = model.playback.time
        let analysis = model.session.analysis
        func frame(_ clip: Clip?, at clipTime: Time? = nil) -> (CGImage, String)? {
            guard let clip, let mediaID = clip.mediaID, let item = project.media(mediaID) else { return nil }
            guard let (strip, folder) = analysis.thumbnails(for: item), !strip.files.isEmpty else { return nil }
            let source = clip.sourceStart + Time(seconds: (clipTime ?? .zero).seconds * clip.speed)
            let index = min(strip.files.count - 1, max(0, Int(source.seconds / max(strip.interval, 0.001))))
            let url = folder.appendingPathComponent(strip.files[index])
            guard let image = PreviewFrameCache.image(at: url) else { return nil }
            return (image, url.lastPathComponent + mediaID)
        }
        // The clip the inspector would show, if it's picture.
        let chosen = model.primaryClipID.flatMap { id in project.clip(id) }.flatMap { clip -> Clip? in
            project.location(ofClip: clip.id)?.track.kind == .video ? clip : nil
        } ?? project.videoTracks.reversed().compactMap { $0.clip(at: time) }.first { $0.mediaID != nil }
        let now = frame(chosen, at: chosen.map { max(.zero, time - $0.start) })
        current = now?.0
        // Either side of the nearest cut on the video tracks, top down.
        var pair: (Clip, Clip)?
        for track in project.videoTracks.reversed() {
            if let cut = TimelineEdits.nearestCut(on: track, to: time, reach: Time(seconds: 30)) {
                pair = (cut.left, cut.right)
                break
            }
        }
        let left = frame(pair?.0, at: pair.map { $0.0.duration - Time(seconds: 0.5) })
        let right = frame(pair?.1, at: Time(seconds: 0.5))
        before = left?.0 ?? now?.0
        after = right?.0
        key = [now?.1, left?.1, right?.1].map { $0 ?? "-" }.joined(separator: "|")
    }
}

/// Thumbnail files decoded once, small.
@MainActor
enum PreviewFrameCache {
    private static let images = NSCache<NSString, CGImage>()

    static func image(at url: URL) -> CGImage? {
        if let cached = images.object(forKey: url.path as NSString) { return cached }
        guard let image = MediaArtwork.decodeThumbnail(at: url.path, maxPixels: 200) else { return nil }
        images.setObject(image, forKey: url.path as NSString)
        return image
    }
}

/// An effect applied to the preview frame, roughly as the render module
/// does it, cached per frame.
private struct EffectPreview: View {
    let definition: EffectDefinition
    let frames: PreviewFrames

    var body: some View {
        switch definition.type {
        case "dropShadow", "border", "roundedCorners":
            styled
        case "pitchShift":
            Image(systemName: "waveform.path")
                .font(.system(size: 18))
                .foregroundStyle(Theme.sfxClip.detail.color)
        default:
            if let image = EffectPreviewRenderer.render(definition.type, frames: frames) {
                Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fill)
            } else {
                placeholder
            }
        }
    }

    /// The frame smaller on the well, with the style on it, as in the design.
    @ViewBuilder
    private var styled: some View {
        let picture = Group {
            if let current = frames.current {
                Image(decorative: current, scale: 1).resizable().aspectRatio(contentMode: .fill)
            } else {
                LinearGradient(colors: [Theme.cameraClip.border.color, Theme.screenClip.fill.color], startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }
        .frame(width: 52, height: 32)
        switch definition.type {
        case "dropShadow":
            picture.clipShape(RoundedRectangle(cornerRadius: 4)).shadow(color: .black.opacity(0.7), radius: 6, y: 5)
        case "border":
            picture.clipShape(RoundedRectangle(cornerRadius: 2)).overlay(RoundedRectangle(cornerRadius: 2).stroke(Color.white, lineWidth: 2))
        default:
            picture.clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private var placeholder: some View {
        Image(systemName: "camera.filters")
            .font(.system(size: 16))
            .foregroundStyle(Theme.tick.color)
    }
}

/// Core Image stand-ins for the render module's effects, for tiles only.
@MainActor
enum EffectPreviewRenderer {
    private static let context = CIContext(options: [.cacheIntermediates: false])
    private static var cache: [String: CGImage] = [:]

    static func render(_ type: String, frames: PreviewFrames) -> CGImage? {
        guard let source = frames.current else { return nil }
        let key = "\(type)|\(frames.key)"
        if let cached = cache[key] { return cached }
        let input = CIImage(cgImage: source)
        let output: CIImage?
        switch type {
        case "colorAdjust":
            let controls = CIFilter.colorControls()
            controls.inputImage = input
            controls.saturation = 1.35
            controls.contrast = 1.12
            let warm = CIFilter.temperatureAndTint()
            warm.inputImage = controls.outputImage
            warm.neutral = CIVector(x: 6500, y: 0)
            warm.targetNeutral = CIVector(x: 5200, y: 0)
            output = warm.outputImage
        case "hsl":
            let hue = CIFilter.hueAdjust()
            hue.inputImage = input
            hue.angle = 0.45
            output = hue.outputImage
        case "colorWheels":
            // Teal shadows and warm highlights, the look the wheels are for.
            let sample: [String: Double] = ["shadowsHue": 190, "shadowsAmount": 45, "highlightsHue": 35, "highlightsAmount": 40]
            output = ColourWheelGrade { sample[$0] ?? 0 }.apply(to: input)
        case "vignette":
            let vignette = CIFilter.vignette()
            vignette.inputImage = input
            vignette.intensity = 1.6
            vignette.radius = 1.4
            output = vignette.outputImage
        case "sharpen":
            let sharpen = CIFilter.sharpenLuminance()
            sharpen.inputImage = input
            sharpen.sharpness = 2
            output = sharpen.outputImage
        case "lut":
            let look = CIFilter.photoEffectChrome()
            look.inputImage = input
            output = look.outputImage
        case "blur":
            let blur = CIFilter.gaussianBlur()
            blur.inputImage = input.clampedToExtent()
            blur.radius = 4
            output = blur.outputImage?.cropped(to: input.extent)
        case "pixelate":
            let pixels = CIFilter.pixellate()
            pixels.inputImage = input.clampedToExtent()
            pixels.scale = 8
            output = pixels.outputImage?.cropped(to: input.extent)
        default:
            output = nil
        }
        guard let output, let image = context.createCGImage(output, from: input.extent) else { return nil }
        if cache.count > 200 { cache.removeAll() }
        cache[key] = image
        return image
    }
}

/// The move between the clips either side of the nearest cut: halfway
/// through at rest, following the pointer while hovered.
private struct TransitionPreview: View {
    let type: TransitionType
    let frames: PreviewFrames
    @State private var hoverProgress: Double?

    /// Where the tile rests: a moment that shows the move (a fade halfway
    /// through is just black).
    private var restingProgress: Double {
        switch type {
        case .fadeToBlack: return 0.3
        case .fadeFromBlack: return 0.72
        case .zoom: return 0.3
        default: return 0.5
        }
    }

    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                draw(in: &context, size: size, progress: hoverProgress ?? restingProgress)
            }
            .contentShape(Rectangle())
            .pointerMoves { point in
                hoverProgress = point.map { min(max($0.x / max(geometry.size.width, 1), 0), 1) }
            }
        }
    }

    private func draw(in context: inout GraphicsContext, size: CGSize, progress p: Double) {
        let rect = CGRect(origin: .zero, size: size)
        let from = picture(frames.before, fallback: Theme.cameraClip.border)
        let to = picture(frames.after, fallback: Theme.brollClip.border)
        func layer(_ shading: GraphicsContext.Shading?, _ image: Image?, in frame: CGRect, opacity: Double = 1, scale: CGFloat = 1) {
            var copy = context
            copy.opacity = opacity
            let scaled = CGRect(x: frame.midX - frame.width * scale / 2, y: frame.midY - frame.height * scale / 2, width: frame.width * scale, height: frame.height * scale)
            if let image { copy.draw(image, in: scaled) } else if let shading { copy.fill(Path(scaled), with: shading) }
        }
        let eased = p < 0.5 ? 2 * p * p : 1 - pow(-2 * p + 2, 2) / 2
        switch type {
        case .dissolve:
            layer(from.0, from.1, in: rect)
            layer(to.0, to.1, in: rect, opacity: p)
        case .fadeToBlack, .fadeFromBlack:
            context.fill(Path(rect), with: .color(.black))
            if p < 0.5 { layer(from.0, from.1, in: rect, opacity: 1 - p * 2) } else { layer(to.0, to.1, in: rect, opacity: p * 2 - 1) }
        case .push, .cutSlide:
            let shift = (type == .cutSlide ? 1 - pow(1 - p, 4) : eased) * size.width
            layer(from.0, from.1, in: rect.offsetBy(dx: -shift, dy: 0))
            layer(to.0, to.1, in: rect.offsetBy(dx: size.width - shift, dy: 0))
        case .slide:
            layer(from.0, from.1, in: rect)
            layer(to.0, to.1, in: rect.offsetBy(dx: (1 - eased) * size.width, dy: 0))
        case .wipe:
            layer(from.0, from.1, in: rect)
            var clipped = context
            clipped.clip(to: Path(CGRect(x: 0, y: 0, width: p * size.width, height: size.height)))
            if let image = to.1 { clipped.draw(image, in: rect) } else if let shading = to.0 { clipped.fill(Path(rect), with: shading) }
            context.fill(Path(CGRect(x: p * size.width - 1, y: 0, width: 2, height: size.height)), with: .color(.white.opacity(0.5)))
        case .zoom:
            if p < 0.5 {
                layer(from.0, from.1, in: rect, opacity: 1, scale: 1 + p * 1.2)
            } else {
                layer(to.0, to.1, in: rect, opacity: 1, scale: 1.6 - (p - 0.5) * 1.2)
            }
        }
    }

    private func picture(_ image: CGImage?, fallback: Swatch) -> (GraphicsContext.Shading?, Image?) {
        if let image { return (nil, Image(decorative: image, scale: 1)) }
        return (.color(fallback.color), nil)
    }
}
