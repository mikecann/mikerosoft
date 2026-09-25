import AppKit
import TandemCore

/// Renders a window to PNG from inside the app, so Tandem can screenshot
/// itself without screen recording permission. SwiftUI draws most of the
/// window into layers that `cacheDisplay` doesn't see, so the capture
/// renders the window's layer tree and uses `cacheDisplay` for views that
/// only draw through `draw(_:)`. Views whose pixels come from elsewhere
/// (the video layer) check `isCapturing` and draw a still instead.
@MainActor
enum WindowSnapshot {
    /// True while a capture is drawing.
    static private(set) var isCapturing = false

    static func image(of window: NSWindow) -> CGImage? {
        guard let view = window.contentView?.superview ?? window.contentView, let layer = view.layer else { return nil }
        view.layoutSubtreeIfNeeded()
        isCapturing = true
        defer {
            isCapturing = false
            // Views that drew a still for the capture go back to live.
            view.setNeedsDisplay(view.bounds)
        }
        // Views that draw differently while capturing redraw now.
        markCaptureViews(in: view)
        view.displayIfNeeded()
        CATransaction.flush()
        let scale = window.backingScaleFactor
        let size = view.bounds.size
        guard size.width > 0, size.height > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8,
                bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        context.scaleBy(x: scale, y: scale)
        layer.render(in: context)
        // Popovers (tighten pauses, pickers) live in child windows; draw
        // them where they sit over this one.
        for child in window.childWindows ?? [] where child.isVisible {
            guard let childView = child.contentView?.superview ?? child.contentView, let childLayer = childView.layer else { continue }
            childView.layoutSubtreeIfNeeded()
            childView.displayIfNeeded()
            context.saveGState()
            context.translateBy(x: child.frame.minX - window.frame.minX, y: child.frame.minY - window.frame.minY)
            childLayer.render(in: context)
            context.restoreGState()
        }
        return context.makeImage()
    }

    /// Views that draw a still while capturing (the viewer) redraw.
    private static func markCaptureViews(in view: NSView) {
        if view is CaptureAware { view.needsDisplay = true }
        for subview in view.subviews { markCaptureViews(in: subview) }
    }

    /// The view and layer tree as text, for debugging layout from agents.
    static func describe(_ window: NSWindow) -> String {
        var lines: [String] = []
        func visit(_ view: NSView, depth: Int) {
            let pad = String(repeating: "  ", count: depth)
            let layer = view.layer.map { " layer=\(type(of: $0)) sublayers=\($0.sublayers?.count ?? 0)" } ?? ""
            lines.append("\(pad)\(type(of: view)) \(NSStringFromRect(view.frame))\(view.isHidden ? " hidden" : "")\(layer)")
            for subview in view.subviews { visit(subview, depth: depth + 1) }
        }
        if let root = window.contentView?.superview ?? window.contentView { visit(root, depth: 0) }
        func visitLayer(_ layer: CALayer, depth: Int) {
            guard depth < 14 else { return }
            let pad = String(repeating: "  ", count: depth)
            lines.append("\(pad)[\(type(of: layer))] \(NSStringFromRect(layer.frame))\(layer.isHidden ? " hidden" : "")\(layer.contents != nil ? " contents" : "")\(layer.backgroundColor != nil ? " bg" : "")")
            for sublayer in layer.sublayers ?? [] { visitLayer(sublayer, depth: depth + 1) }
        }
        lines.append("--- draw timing")
        lines.append(DrawTiming.summary)
        lines.append("--- layers")
        if let layer = window.contentView?.layer { visitLayer(layer, depth: 0) }
        return lines.joined(separator: "\n")
    }

    /// The window as PNG data.
    static func pngData(of window: NSWindow) throws -> Data {
        guard let image = image(of: window) else { throw EditError.invalid("couldn't render the window") }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw EditError.invalid("couldn't encode the screenshot")
        }
        return data
    }

    static func write(_ window: NSWindow, to url: URL) throws {
        let data = try pngData(of: window)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}

/// A view that draws something different (a still) while the window is
/// being captured.
protocol CaptureAware: AnyObject {}

/// Commands the app takes through `tandem://` URLs, for smoke tests and
/// agents: `open -g "tandem://screenshot?out=/tmp/shot.png"`.
enum AppURLCommand: Equatable {
    /// Writes the front project window (or the welcome window) to a PNG.
    case screenshot(out: String)
    case open(path: String)
    /// Runs an editor command by its keymap name.
    case command(EditorCommand)
    case seek(Time)
    case select(clipIDs: [String])
    case panels(library: LibraryTab?, inspector: InspectorTab?, exportSheet: Bool?)
    case zoom(pixelsPerSecond: Double?, scrollSeconds: Double?)
    case tool(TimelineTool)
    case inOut(start: Time?, end: Time?)
    /// Writes the window's view and layer tree to a text file.
    case debug(out: String)
    /// Replays a mouse gesture; see `InputSimulator`.
    case simulate(InputSimulator.Gesture)
    /// Makes a project in a folder, or opens the one already there.
    case newProject(folder: String)
    /// Saves the front project as a new file and carries on editing that.
    case saveVersion(out: String)

    static func parse(_ url: URL) -> AppURLCommand? {
        guard url.scheme?.lowercased() == "tandem", let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let action = (url.host ?? components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))).lowercased()
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] { query[item.name.lowercased()] = item.value ?? "" }
        switch action {
        case "screenshot":
            guard let out = path(query["out"], extension: "png") else { return nil }
            return .screenshot(out: out)
        case "open":
            guard let path = query["path"], !path.isEmpty else { return nil }
            return .open(path: NSString(string: path).expandingTildeInPath)
        case "command", "run":
            guard let name = query["name"], let command = EditorCommand(rawValue: name) else { return nil }
            return .command(command)
        case "seek", "playhead":
            guard let text = query["t"] ?? query["time"], let seconds = Double(text) else { return nil }
            return .seek(Time(seconds: seconds))
        case "select":
            let ids = (query["clips"] ?? query["clip"] ?? "").split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return .select(clipIDs: ids)
        case "panel", "panels", "tab":
            let library = query["library"].flatMap(LibraryTab.init(rawValue:))
            let inspector = query["inspector"].flatMap { InspectorTab(rawValue: $0 == "color" ? "colour" : $0) }
            let sheet = query["sheet"].map { $0 == "export" }
            guard library != nil || inspector != nil || sheet != nil else { return nil }
            return .panels(library: library, inspector: inspector, exportSheet: sheet)
        case "zoom":
            let pps = query["pps"].flatMap(Double.init)
            let scroll = query["scroll"].flatMap(Double.init)
            guard pps != nil || scroll != nil else { return nil }
            return .zoom(pixelsPerSecond: pps, scrollSeconds: scroll)
        case "tool":
            guard let name = query["name"], let tool = TimelineTool(rawValue: name) else { return nil }
            return .tool(tool)
        case "simulate":
            guard let gesture = InputSimulator.parse(query) else { return nil }
            return .simulate(gesture)
        case "debug":
            guard let out = path(query["out"], extension: "txt") else { return nil }
            return .debug(out: out)
        case "new":
            guard let folder = path(query["folder"]) else { return nil }
            return .newProject(folder: folder)
        case "version", "saveas":
            guard let out = path(query["out"], extension: ProjectFile.fileExtension) else { return nil }
            return .saveVersion(out: out)
        case "inout":
            let start = query["in"].flatMap(Double.init).map { Time(seconds: $0) }
            let end = query["out"].flatMap(Double.init).map { Time(seconds: $0) }
            return .inOut(start: start, end: end)
        default:
            return nil
        }
    }

    /// An absolute path, after `~` expansion, with the extension the command
    /// writes. Any app or web page can open a tandem:// link, so a
    /// screenshot mustn't be able to overwrite, say, a shell profile.
    private static func path(_ raw: String?, extension required: String? = nil) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let path = NSString(string: raw).expandingTildeInPath
        guard path.hasPrefix("/") else { return nil }
        if let required, URL(fileURLWithPath: path).pathExtension.lowercased() != required { return nil }
        return path
    }
}
