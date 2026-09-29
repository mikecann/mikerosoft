import AppKit
import ImageIO
import Observation
import TandemAPI
import TandemCore
import TandemMedia
import TandemRender
import UniformTypeIdentifiers

/// Where a project's icon lives: `.tandem/<name>.icon.png`, beside its
/// journal, so each project file in a folder has its own.
enum ProjectIconFile {
    static func url(for projectURL: URL) -> URL {
        ProjectFolder(projectFile: projectURL).supportFolder
            .appendingPathComponent("\(projectURL.deletingPathExtension().lastPathComponent).icon.png")
    }

    /// The icon's pixel size: small, and 16:9 like the videos.
    static let size = CGSize(width: 320, height: 180)
}

/// Which frame a project's icon shows.
enum ProjectIconFrame {
    /// A tenth of the way in when there's a picture there, else a moment
    /// into the first picture. Nil when there's nothing to show.
    static func time(in project: Project) -> Time? {
        let pictures = project.videoTracks.filter { !$0.hidden }.flatMap(\.clips)
        guard project.duration > .zero, let first = pictures.min(by: { $0.start < $1.start }) else { return nil }
        let tenth = Time(seconds: project.duration.seconds * 0.1)
        if pictures.contains(where: { $0.start <= tenth && tenth < $0.end }) { return tenth }
        return first.start + Time(seconds: min(1, first.duration.seconds / 2))
    }

    /// True for a frame too dark to tell apart from another: media that's
    /// offline, or a fade.
    static func isBlank(_ image: CGImage) -> Bool {
        let side = 8
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let context = CGContext(
            data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        let brightest = stride(from: 0, to: pixels.count, by: 4).map { max(pixels[$0], pixels[$0 + 1], pixels[$0 + 2]) }.max() ?? 0
        return brightest < 8
    }
}

/// When a project's icon is made again. Rendering a frame builds the whole
/// composition, so saves (every edit or so) only refresh it now and then.
enum ProjectIconSchedule {
    enum Reason {
        case opened, saved, closed
    }

    /// How long after one icon a save can make another.
    static let saveInterval: TimeInterval = 120

    static func shouldRender(_ reason: Reason, iconExists: Bool, last: (date: Date, revision: Int)?, revision: Int, now: Date = Date()) -> Bool {
        let changed = last?.revision != revision
        switch reason {
        case .opened:
            return !iconExists
        case .saved:
            guard iconExists else { return last.map { now.timeIntervalSince($0.date) >= saveInterval } ?? true }
            return changed && (last.map { now.timeIntervalSince($0.date) >= saveInterval } ?? true)
        case .closed:
            return !iconExists || changed
        }
    }
}

/// Each project's icon: a real frame, made off the main thread with
/// `FrameRenderer` when the project is opened without one, saved (now and
/// then) or closed, and read back for the project list and Open recent.
/// Lists never wait: they get the placeholder until the icon has loaded.
@MainActor
@Observable
final class ProjectIcons {
    static let shared = ProjectIcons()

    /// Goes up when an icon loads or is made, so lists draw it.
    private(set) var revision = 0

    @ObservationIgnored private var images: [String: NSImage] = [:]
    @ObservationIgnored private var menuImages: [String: NSImage] = [:]
    @ObservationIgnored private var loading: Set<String> = []
    /// Projects without an icon file, as of the last look.
    @ObservationIgnored private var missing: Set<String> = []
    @ObservationIgnored private var rendering: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var rendered: [String: (date: Date, revision: Int)] = [:]
    /// Recent projects waiting for an icon, made one at a time.
    @ObservationIgnored private var queue: [String] = []
    @ObservationIgnored private var queueRunning = false
    /// Projects already tried this run, so a project whose media is offline
    /// isn't tried over and over.
    @ObservationIgnored private var tried: Set<String> = []

    private static func key(_ url: URL) -> String { url.standardizedFileURL.path }

    // MARK: - Reading

    /// The icon, if it's loaded. Otherwise starts loading it (or making it,
    /// for a project that has none) and returns nil for now.
    func image(for projectURL: URL) -> NSImage? {
        let key = Self.key(projectURL)
        if let image = images[key] { return image }
        if missing.contains(key) {
            makeLater(key)
        } else if !loading.contains(key) {
            loading.insert(key)
            let file = ProjectIconFile.url(for: projectURL)
            Task.detached(priority: .utility) {
                let image = CGImageSourceCreateWithURL(file as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
                await ProjectIcons.shared.loaded(key, image)
            }
        }
        return nil
    }

    private func loaded(_ key: String, _ image: CGImage?) {
        loading.remove(key)
        guard let image else {
            missing.insert(key)
            makeLater(key)
            return
        }
        store(key, image)
    }

    private func store(_ key: String, _ image: CGImage) {
        images[key] = NSImage(cgImage: image, size: NSSize(width: image.width / 2, height: image.height / 2))
        menuImages[key] = nil
        missing.remove(key)
        revision += 1
    }

    /// The icon at menu size, or the placeholder, for Open recent.
    func menuImage(for projectURL: URL) -> NSImage {
        let key = Self.key(projectURL)
        if let cached = menuImages[key] { return cached }
        guard let image = image(for: projectURL) else { return Self.menuPlaceholder }
        let small = Self.rounded(image, size: NSSize(width: 32, height: 18))
        menuImages[key] = small
        return small
    }

    private static func rounded(_ image: NSImage, size: NSSize) -> NSImage {
        NSImage(size: size, flipped: false) { rect in
            NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).addClip()
            image.draw(in: rect)
            return true
        }
    }

    static let menuPlaceholder: NSImage = NSImage(size: NSSize(width: 32, height: 18), flipped: false) { rect in
        Theme.field.ns.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
        if let film = NSImage(systemSymbolName: "film", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 9, weight: .regular)) {
            let tinted = NSImage(size: film.size, flipped: false) { box in
                film.draw(in: box)
                Theme.textFaint.ns.set()
                box.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(at: NSPoint(x: rect.midX - film.size.width / 2, y: rect.midY - film.size.height / 2), from: .zero, operation: .sourceOver, fraction: 1)
        }
        return true
    }

    // MARK: - Making

    /// Brings an open project's icon up to date, when `reason` calls for it.
    func refresh(_ reason: ProjectIconSchedule.Reason, project: Project, revision: Int, fileURL: URL, folder: ProjectFolder, analysis: MediaAnalysis?) {
        let key = Self.key(fileURL)
        let exists = FileManager.default.fileExists(atPath: ProjectIconFile.url(for: fileURL).path)
        guard ProjectIconSchedule.shouldRender(reason, iconExists: exists, last: rendered[key], revision: revision) else { return }
        render(key, revision: revision) {
            await Self.make(project: project, folder: folder, analysis: analysis, file: ProjectIconFile.url(for: fileURL))
        }
    }

    func refresh(_ reason: ProjectIconSchedule.Reason, for model: EditorModel) {
        let (project, revision) = model.session.coordinator.snapshot()
        refresh(reason, project: project, revision: revision, fileURL: model.fileURL, folder: model.folder, analysis: model.session.analysis)
    }

    private func render(_ key: String, revision: Int, make: @escaping @Sendable () async -> CGImage?) {
        guard rendering[key] == nil else { return }
        rendered[key] = (Date(), revision)
        let work = Task.detached(priority: .utility) { await make() }
        rendering[key] = Task {
            let image = await work.value
            self.rendering[key] = nil
            if let image { self.store(key, image) }
        }
    }

    /// A recent project that isn't open and has no icon gets one, in the
    /// background and one at a time. Skipped when another Tandem has it
    /// open: that one makes it.
    private func makeLater(_ key: String) {
        guard !tried.contains(key), rendering[key] == nil else { return }
        tried.insert(key)
        queue.append(key)
        guard !queueRunning else { return }
        queueRunning = true
        Task {
            while !self.queue.isEmpty {
                let next = self.queue.removeFirst()
                let url = URL(fileURLWithPath: next)
                let image = await Task.detached(priority: .background) { () -> CGImage? in
                    guard FileManager.default.fileExists(atPath: url.path), ProjectSession.liveLock(for: url) == nil,
                          let (project, _) = try? ProjectFile.load(from: url) else { return nil }
                    return await ProjectIcons.make(project: project, folder: ProjectFolder(projectFile: url), analysis: nil, file: ProjectIconFile.url(for: url))
                }.value
                if let image { self.store(next, image) }
            }
            self.queueRunning = false
        }
    }

    /// Renders the icon frame and writes it. Nil (keeping any icon there)
    /// when the frame can't be made or is blank.
    nonisolated static func make(project: Project, folder: ProjectFolder, analysis: MediaAnalysis?, file: URL) async -> CGImage? {
        guard let time = ProjectIconFrame.time(in: project) else {
            // Nothing on the timeline: the list shows the placeholder.
            try? FileManager.default.removeItem(at: file)
            return nil
        }
        let context = RenderContext(project: project, folder: folder, analysis: analysis, useProxies: analysis != nil)
        guard let image = try? await FrameRenderer(context: context).image(at: time, maxSize: ProjectIconFile.size),
              !ProjectIconFrame.isBlank(image) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? (data as Data).write(to: file, options: .atomic)
        return image
    }

    // MARK: - Quitting

    /// True while icons are still being made, so quitting can wait a
    /// moment for them.
    var isBusy: Bool { !rendering.isEmpty }
}
