import Foundation
import TandemCore

/// What an export preset makes of one project: the frame it renders (the
/// canvas or an alternate format), the size and the bitrate. The CLI, the
/// API, the exporter and the app's Export dialog all go through
/// `ExportPreset.plan(for:)`, so they agree.
///
/// A preset sets the quality and the project sets the shape:
/// - A preset with a `resolution` scales the frame so its short side is
///   that many pixels, keeping its shape. YouTube 1080p is 1920x1080 on a
///   landscape canvas, 1080x1920 on a 9:16 one and 1080x1080 on a square.
///   An exact `width` and `height` win, and with neither the frame keeps
///   its own size.
/// - A preset's bitrate is for a 16:9 frame of its class at up to 30 fps.
///   It follows the frame's area (a square gets 56% of it) and gets half
///   as much again above 30 fps, as YouTube's recommendations do.
/// - Bigger than the frame is allowed (YouTube 4K of a 1080p canvas) but
///   comes with a warning, since upscaling adds no detail.
/// - "portrait" is the project's 9:16 frame: its portrait format, or the
///   canvas itself when that's 9:16.
public struct ExportPlan: Equatable, Sendable {
    /// The preset to render with, with its format, size and bitrate filled
    /// in: planning it again gives the same plan.
    public var preset: ExportPreset
    /// The alternate format rendered, or nil for the main canvas.
    public var format: String?
    /// The frame it's rendered from: the canvas, or the format's frame.
    public var frameWidth: Int
    public var frameHeight: Int
    public var width: Int
    public var height: Int
    /// Worth knowing before it renders, like an upscale.
    public var warnings: [String]

    public var codec: ExportPreset.Codec { preset.codec }
    public var videoBitrate: Int { preset.videoBitrate }
    public var isUpscaled: Bool { width > frameWidth || height > frameHeight }

    /// "1080x1920 H.264 at 20 Mbps"
    public var summary: String { "\(width)x\(height) \(codec.displayName) at \(Self.megabits(videoBitrate))" }

    /// "20 Mbps", "11.3 Mbps".
    public static func megabits(_ bitsPerSecond: Int) -> String {
        let tenths = (Double(bitsPerSecond) / 100_000).rounded()
        let whole = tenths.truncatingRemainder(dividingBy: 10) == 0
        return whole ? "\(Int(tenths / 10)) Mbps" : String(format: "%.1f Mbps", tenths / 10)
    }
}

/// Why a preset can't render a project.
public enum ExportPlanError: Error, Equatable, CustomStringConvertible, LocalizedError {
    /// The short (or `format: "portrait"`) on a project with no 9:16 frame:
    /// its canvas isn't 9:16 and it has no portrait format.
    case noPortrait(width: Int, height: Int)
    /// An alternate format the project doesn't have.
    case noFormat(id: String, known: [String])

    public var description: String {
        switch self {
        case let .noPortrait(width, height):
            let canvas = ExportPreset.standard(forFrame: width, height).cliName
            return "This \(width)x\(height) project has no 9:16 frame for the short: its canvas isn't 9:16 and it has no portrait format. "
                + "Make one with `tandem short --apply` (screen on top, camera below), or add the portrait format with updateSettings "
                + "(alternateFormats) and place clips in it with setFormatLayout. To export the canvas as it is, use --preset \(canvas)."
        case let .noFormat(id, known):
            return "No output format \"\(id)\". This project has: \((["main"] + known).joined(separator: ", "))."
        }
    }

    public var errorDescription: String? { description }
}

extension ExportPreset {
    /// What this preset renders for a project with these settings.
    /// `format` (an alternate format ID, or "main" for the canvas) picks
    /// the frame instead of the preset's own. Throws `ExportPlanError` when
    /// the project doesn't have that frame.
    public func plan(for settings: ProjectSettings, format requested: String? = nil) throws -> ExportPlan {
        let format = try OutputFrames.resolve(requested ?? self.format, in: settings)
        let frame = OutputFrames.size(of: format, in: settings)
        var planned = self
        planned.format = format ?? OutputFrames.main
        var width = frame.width
        var height = frame.height
        if let exactWidth = self.width, let exactHeight = self.height {
            width = exactWidth
            height = exactHeight
        } else if let resolution {
            // The frame's short side becomes the resolution, keeping its
            // shape, in even numbers as 4:2:0 video needs.
            let scale = Double(resolution) / Double(max(1, min(frame.width, frame.height)))
            width = Self.even(Double(frame.width) * scale)
            height = Self.even(Double(frame.height) * scale)
            // The rate is for a 16:9 frame of the class at up to 30 fps.
            let reference = Double(resolution) * Double(resolution) * 16 / 9
            var bitrate = Double(videoBitrate) * Double(width * height) / reference
            if settings.frameRate.framesPerSecond > 30.5 { bitrate *= 1.5 }
            planned.videoBitrate = max(1, Int((bitrate / 100_000).rounded())) * 100_000
        }
        planned.width = width
        planned.height = height
        planned.resolution = nil
        var warnings: [String] = []
        if width > frame.width || height > frame.height {
            let source = format.flatMap { id in settings.alternateFormats.first { $0.id == id } }
            let what = source.map { "\($0.name) format" } ?? "canvas"
            let noun = source == nil ? "canvas" : "format"
            warnings.append("\(name) upscales the \(frame.width)x\(frame.height) \(what) to \(width)x\(height), so it's no sharper than the \(noun).")
        }
        return ExportPlan(
            preset: planned, format: format, frameWidth: frame.width, frameHeight: frame.height,
            width: width, height: height, warnings: warnings
        )
    }

    /// The preset an export uses when none is named: the YouTube preset of
    /// the frame's resolution class. A frame 1080 pixels or less on its
    /// short side (1920x1080, 1080x1920, 1080x1080) gets YouTube 1080p,
    /// anything bigger YouTube 4K.
    public static func standard(for settings: ProjectSettings, format: String? = nil) -> ExportPreset {
        // A frame the project hasn't got falls back to the canvas; planning
        // the export says what's missing.
        let frame = OutputFrames.size(of: try? OutputFrames.resolve(format, in: settings), in: settings)
        return standard(forFrame: frame.width, frame.height)
    }

    static func standard(forFrame width: Int, _ height: Int) -> ExportPreset {
        min(width, height) > 1080 ? .youtube4K : .youtube1080
    }

    static func even(_ value: Double) -> Int {
        max(2, Int((value / 2).rounded()) * 2)
    }
}

/// The frames a project renders: its main canvas and its alternate formats.
public enum OutputFrames {
    /// The ID that asks for the main canvas.
    public static let main = "main"

    /// The alternate format to render for `requested`, or nil for the main
    /// canvas. Nil and "main" are the canvas. "portrait" on a project
    /// without that format whose canvas is 9:16 is the canvas too.
    public static func resolve(_ requested: String?, in settings: ProjectSettings) throws -> String? {
        guard let requested, requested != main else { return nil }
        if settings.alternateFormats.contains(where: { $0.id == requested }) { return requested }
        if requested == OutputFormat.portrait.id {
            if isNineBySixteen(width: settings.width, height: settings.height) { return nil }
            throw ExportPlanError.noPortrait(width: settings.width, height: settings.height)
        }
        throw ExportPlanError.noFormat(id: requested, known: settings.alternateFormats.map(\.id))
    }

    /// The size of a resolved format's frame (nil for the canvas).
    public static func size(of format: String?, in settings: ProjectSettings) -> (width: Int, height: Int) {
        if let format, let alternate = settings.alternateFormats.first(where: { $0.id == format }) {
            return (alternate.width, alternate.height)
        }
        return (settings.width, settings.height)
    }

    /// 9:16 to within rounding, like 1080x1920 or 2160x3840.
    public static func isNineBySixteen(width: Int, height: Int) -> Bool {
        guard width > 0, height > 0 else { return false }
        return abs(Double(width) / Double(height) - 9.0 / 16.0) < 0.005
    }
}

extension ExportPreset {
    /// The name the CLI and the API take: youtube4k, youtube1080, review
    /// or short (any spelling of the full name works too).
    public var cliName: String {
        switch name {
        case ExportPreset.youtube4K.name: return "youtube4k"
        case ExportPreset.youtube1080.name: return "youtube1080"
        case ExportPreset.review.name: return "review"
        case ExportPreset.short.name: return "short"
        default: return name
        }
    }
}
