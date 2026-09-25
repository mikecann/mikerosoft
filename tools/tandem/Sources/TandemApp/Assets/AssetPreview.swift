import AVFoundation
import AppKit
import ImageIO
import SwiftUI
import TandemAssets
import TandemCore

/// The big preview Space opens over the viewer, as Quick Look does in
/// Finder: the asset large and playing (stickers and clips loop, sound
/// plays from the start), what it is and where it's from, and the button
/// that uses it. Space or Escape closes it; hovering another asset and
/// pressing Space shows that one instead.
struct AssetPreviewLayer: View {
    let model: EditorModel

    var body: some View {
        let host = AssetLibraryHost.shared
        if let asset = host.previewing {
            ZStack {
                Theme.dimmer.color
                    .contentShape(Rectangle())
                    .onTapGesture { host.previewing = nil }
                AssetPreviewCard(model: model, asset: asset)
                    .id(asset.id)
                    .padding(24)
            }
        }
    }
}

private struct AssetPreviewCard: View {
    let model: EditorModel
    let asset: Asset

    var body: some View {
        let host = AssetLibraryHost.shared
        let favourite = host.previewing?.id == asset.id ? (host.previewing?.isFavourite ?? asset.isFavourite) : asset.isFavourite
        VStack(alignment: .leading, spacing: 12) {
            AssetPreviewStage(asset: asset)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.viewer.color))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(asset.name)
                        .font(.ui(14, .bold))
                        .foregroundStyle(Theme.text.color)
                        .lineLimit(2)
                    Text(details)
                        .font(.ui(11.5))
                        .foregroundStyle(Theme.textMuted.color)
                        .lineLimit(2)
                    if let credit = asset.creditLine {
                        Text("Credit: \(credit)")
                            .font(.ui(11))
                            .foregroundStyle(Theme.textFaint.color)
                            .lineLimit(2)
                            .textSelection(.enabled)
                    }
                    if asset.licenceClass == .aiGenerated, let prompt = asset.summary {
                        Text("Made from \u{201C}\(prompt)\u{201D}")
                            .font(.ui(11))
                            .foregroundStyle(Theme.textFaint.color)
                            .lineLimit(3)
                            .textSelection(.enabled)
                    }
                }
                Spacer(minLength: 8)
                FavouriteStar(on: favourite) {
                    host.setFavourite(asset, !favourite)
                    host.previewing?.isFavourite = !favourite
                }
                Button {
                    host.previewing = nil
                    host.use(asset, in: model)
                } label: {
                    Text(useTitle)
                        .font(.ui(12, .bold))
                        .foregroundStyle(Theme.onAmber.color)
                        .padding(.horizontal, 12)
                        .frame(height: 26)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.amber.color))
                }
                .buttonStyle(.plain)
            }
            Text("Space or Esc closes the preview.")
                .font(.ui(10.5))
                .foregroundStyle(Theme.textFaint.color)
        }
        .padding(14)
        .frame(maxWidth: 760, maxHeight: 600)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.panel.color))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.controlBorder.color, lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 24, y: 10)
    }

    /// "Noto · No credit · 0:03 · 512 × 512 · Downloaded"
    private var details: String {
        let host = AssetLibraryHost.shared
        var parts = [host.providers.first { $0.id == asset.provider }.map { AssetBrowsing.sourceName($0.displayName) } ?? asset.provider]
        parts.append(asset.licenceClass.label)
        let length = AssetBrowsing.details(asset)
        if !length.isEmpty { parts.append(length) }
        if let width = asset.width, let height = asset.height { parts.append("\(width) × \(height)") }
        parts.append(asset.state >= .original ? "Downloaded" : "Downloads when you use it")
        return parts.joined(separator: " · ")
    }

    private var useTitle: String {
        switch asset.kind {
        case .lut: return "Grade the selected clips"
        case .font: return "Use for the selected titles"
        default: return "Add at the playhead"
        }
    }
}

/// The asset itself: a looping movie, an animation, a picture, a waveform
/// that plays, or a font's letters.
private struct AssetPreviewStage: View {
    let asset: Asset
    @State private var content: Content = .loading

    enum Content {
        case loading
        case movie(URL)
        case frames(AnimatedFrames)
        case image(NSImage)
        case audio
        case font(String?)
        case missing(String)
    }

    var body: some View {
        Group {
            switch content {
            case .loading:
                ProgressView().controlSize(.small)
            case .movie(let url):
                LoopingMovie(url: url).padding(pads ? 24 : 0)
            case .frames(let frames):
                AnimatedFramesView(frames: frames).padding(pads ? 24 : 0)
            case .image(let image):
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).padding(pads ? 32 : 0)
            case .audio:
                BigWaveform(asset: asset).padding(20)
            case .font(let face):
                FontSample(asset: asset, face: face).padding(24)
            case .missing(let message):
                Text(message).font(.ui(12)).foregroundStyle(Theme.textFaint.color).multilineTextAlignment(.center).padding(24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(minHeight: asset.kind.isAudio ? 160 : 280)
        .task(id: asset.id) { content = await load() }
        .onDisappear {
            let media = AssetLibraryHost.shared.media
            if media.auditioning == asset.id { media.stopAudition() }
        }
    }

    /// Stickers, icons and logos sit inside the stage; clips and looks fill it.
    private var pads: Bool {
        switch asset.kind {
        case .video, .lut, .image: return false
        default: return true
        }
    }

    private func load() async -> Content {
        let host = AssetLibraryHost.shared
        guard let library = host.library else { return .missing("The asset library isn't open yet.") }
        switch asset.kind {
        case .music, .sfx:
            // Plays from the start, as Quick Look does.
            Task { await host.media.audition(asset, from: 0) }
            return .audio
        case .font:
            return .font(await host.fontFace(for: asset))
        case .sticker, .video, .overlay:
            if let url = await AssetMedia.localOrPreview(asset, library: library) {
                if ["mov", "mp4", "m4v"].contains(url.pathExtension.lowercased()) { return .movie(url) }
                if let frames = await Task.detached(priority: .userInitiated, operation: { AnimatedFrames.load(url) }).value { return .frames(frames) }
                if let image = NSImage(contentsOf: url) { return .image(image) }
            }
        case .image:
            if let local = library.playableURL(for: asset), FileManager.default.fileExists(atPath: local.path), let image = NSImage(contentsOf: local) {
                return .image(image)
            }
        default:
            break
        }
        if let image = await host.media.thumbnail(for: asset) { return .image(image) }
        return .missing("No preview for \(asset.name) yet.")
    }
}

// MARK: - Movies

/// A muted movie that loops.
private struct LoopingMovie: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> LoopingMovieView {
        let view = LoopingMovieView()
        view.load(url)
        return view
    }

    func updateNSView(_ view: LoopingMovieView, context: Context) {
        view.load(url)
    }

    static func dismantleNSView(_ view: LoopingMovieView, coordinator: ()) {
        view.stop()
    }
}

/// Plays a movie over and over in a video layer. The video layer isn't
/// in a window capture, so while one is drawing this draws a still.
final class LoopingMovieView: NSView, CaptureAware {
    private let player = AVQueuePlayer()
    private var looper: AVPlayerLooper?
    private let playerLayer = AVPlayerLayer()
    private var poster: CGImage?
    private var url: URL?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        player.isMuted = true
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspect
        layer?.addSublayer(playerLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func load(_ url: URL) {
        guard url != self.url else { return }
        self.url = url
        looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        player.play()
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 960, height: 960)
        let box = Unchecked(generator)
        Task { [weak self] in
            let still = try? await box.value.image(at: CMTime(seconds: 0.4, preferredTimescale: 600)).image
            self?.poster = still
        }
    }

    func stop() {
        player.pause()
        looper = nil
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard WindowSnapshot.isCapturing, let poster, let context = NSGraphicsContext.current?.cgContext else { return }
        context.draw(poster, in: AVMakeRect(aspectRatio: CGSize(width: poster.width, height: poster.height), insideRect: bounds))
    }
}

// MARK: - Animations

/// The frames of an animated WebP, GIF or PNG, with how long each shows.
struct AnimatedFrames: @unchecked Sendable {
    var images: [CGImage]
    var delays: [Double]

    var total: Double { delays.reduce(0, +) }

    /// Nil for a still or a file that can't be read.
    static func load(_ url: URL, maxPixels: Int = 720, limit: Int = 300) -> AnimatedFrames? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let count = min(CGImageSourceGetCount(source), limit)
        guard count > 1 else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels
        ]
        var images: [CGImage] = []
        var delays: [Double] = []
        for index in 0..<count {
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else { continue }
            images.append(image)
            delays.append(delay(at: index, in: source))
        }
        return images.count > 1 ? AnimatedFrames(images: images, delays: delays) : nil
    }

    /// A frame's delay from whichever format's dictionary has one; 20 ms
    /// or less means "as fast as you like", which browsers show at 100 ms.
    private static func delay(at index: Int, in source: CGImageSource) -> Double {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
        let pairs: [(CFString, CFString, CFString)] = [
            (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime),
            (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPDelayTime),
            (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime)
        ]
        for (dictionary, unclamped, clamped) in pairs {
            guard let values = properties[dictionary] as? [CFString: Any] else { continue }
            if let value = (values[unclamped] as? Double) ?? (values[clamped] as? Double) {
                return value <= 0.02 ? 0.1 : value
            }
        }
        return 0.05
    }

    /// The frame showing `seconds` into the loop.
    func index(at seconds: Double) -> Int {
        let total = total
        guard total > 0 else { return 0 }
        var remaining = seconds.truncatingRemainder(dividingBy: total)
        for (index, delay) in delays.enumerated() {
            if remaining < delay { return index }
            remaining -= delay
        }
        return images.count - 1
    }
}

private struct AnimatedFramesView: View {
    let frames: AnimatedFrames

    var body: some View {
        TimelineView(.animation) { context in
            let index = frames.index(at: context.date.timeIntervalSinceReferenceDate)
            Image(decorative: frames.images[index], scale: 1).resizable().aspectRatio(contentMode: .fit)
        }
    }
}

// MARK: - Sound

/// The whole waveform, large: click to play from a point, the button to
/// stop and start.
private struct BigWaveform: View {
    let asset: Asset
    @State private var peaks: [Float]?

    var body: some View {
        let media = AssetLibraryHost.shared.media
        HStack(spacing: 14) {
            TimelineView(.animation(minimumInterval: 1.0 / 20)) { _ in
                let playing = media.auditionProgress(of: asset) != nil
                Button {
                    if playing { media.stopAudition() } else { Task { await media.audition(asset, from: 0) } }
                } label: {
                    Image(systemName: playing ? "stop.fill" : "play.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.onAmber.color)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(Theme.amber.color))
                }
                .buttonStyle(.plain)
                .help(playing ? "Stop" : "Play from the start")
            }
            GeometryReader { geometry in
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { _ in
                    Canvas { context, size in
                        let colour = asset.kind == .music ? Theme.musicClip.detail : Theme.sfxClip.detail
                        let mid = size.height / 2
                        if let peaks {
                            let columns = WaveformStrip.columns(peaks, count: max(1, Int(size.width / 3)))
                            var path = Path()
                            for (index, value) in columns.enumerated() {
                                let height = max(1, CGFloat(value) * (size.height - 4))
                                path.addRoundedRect(in: CGRect(x: CGFloat(index) * 3, y: mid - height / 2, width: 2, height: height), cornerSize: CGSize(width: 1, height: 1))
                            }
                            context.fill(path, with: .color(colour.color.opacity(0.9)))
                        } else {
                            context.fill(Path(CGRect(x: 0, y: mid - 0.5, width: size.width, height: 1)), with: .color(colour.color.opacity(0.4)))
                        }
                        if let progress = media.auditionProgress(of: asset) {
                            context.fill(Path(CGRect(x: CGFloat(progress) * size.width, y: 0, width: 2, height: size.height)), with: .color(Theme.amber.color))
                        }
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { location in
                    let fraction = min(max(location.x / max(geometry.size.width, 1), 0), 1)
                    Task { await media.audition(asset, from: fraction) }
                }
            }
            .frame(height: 110)
        }
        .task(id: asset.id) { peaks = await media.waveform(for: asset, allowDownload: true) }
    }
}

// MARK: - Fonts

/// A font's letters, once it's downloaded.
private struct FontSample: View {
    let asset: Asset
    let face: String?

    var body: some View {
        if let face {
            VStack(alignment: .leading, spacing: 10) {
                Text("Aa Bb Cc 0123")
                    .font(.custom(face, size: 64))
                    .foregroundStyle(Theme.text.color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.4)
                Text("The quick brown fox jumps over the lazy dog")
                    .font(.custom(face, size: 26))
                    .foregroundStyle(Theme.textSecondary.color)
                    .lineLimit(2)
                    .minimumScaleFactor(0.5)
                Text(asset.summary ?? asset.name)
                    .font(.ui(11.5))
                    .foregroundStyle(Theme.textFaint.color)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(spacing: 10) {
                Text(asset.name)
                    .font(.ui(34, .bold))
                    .foregroundStyle(Theme.text.color)
                Text("Downloads when you use it, then shows in its own letters.")
                    .font(.ui(12))
                    .foregroundStyle(Theme.textFaint.color)
                Button("Download now") {
                    AssetLibraryHost.shared.download(asset) { _ in }
                }
                .buttonStyle(.plain)
                .font(.ui(12, .semibold))
                .foregroundStyle(Theme.amber.color)
            }
        }
    }
}
