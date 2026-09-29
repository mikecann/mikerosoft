import AppKit
import SwiftUI

/// The Graphite look: dark graphite panels, one amber accent, dense but calm.
/// Every colour and size the app draws with lives here, taken from the
/// Paper design ("1 · Graphite: main editor" and its siblings), so the look
/// can be tuned in one place.
enum Theme {
    // MARK: - Surfaces

    /// The window and the timeline background.
    static let window = Swatch(0x0C0D0F)
    /// Behind the viewer canvas.
    static let viewer = Swatch(0x0A0B0C)
    /// Top bar, media panel and inspector.
    static let panel = Swatch(0x111315)
    static let statusBar = Swatch(0x0F1113)
    /// Sheets, the agent chip and other raised surfaces.
    static let raised = Swatch(0x15171A)
    /// Search fields, chips, effect rows and the segmented control track.
    static let field = Swatch(0x1A1D21)
    static let fieldBorder = Swatch(0x24282D)
    static let rowSelected = Swatch(0x1C1F23)
    /// The selected library tab and timeline tool.
    static let tabSelected = Swatch(0x1D2024)
    static let presetSelected = Swatch(0x23272C)
    static let segmentSelected = Swatch(0x2A2E33)

    // MARK: - Lines

    static let border = Swatch(0x1F2226)
    static let borderSubtle = Swatch(0x1A1D20)
    static let rulerLine = Swatch(0x1D2024)
    static let controlBorder = Swatch(0x2A2E33)
    static let buttonBorder = Swatch(0x2F3338)
    static let sheetDivider = Swatch(0x23272C)
    static let tick = Swatch(0x3A3F45)

    // MARK: - Text

    static let text = Swatch(0xE8EAED)
    static let textStrong = Swatch(0xC9CDD2)
    static let textSecondary = Swatch(0xAEB3B9)
    static let textMuted = Swatch(0x8A9099)
    static let textFaint = Swatch(0x6E747C)
    static let textFainter = Swatch(0x5E646C)

    // MARK: - Accents

    static let amber = Swatch(0xFFB224)
    /// Text and icons drawn on amber.
    static let onAmber = Swatch(0x0C0D0F)
    static let green = Swatch(0x5CC98F)
    static let red = Swatch(0xE5484D)
    static let sliderTrack = Swatch(0x2A2E33)
    static let sliderFill = Swatch(0xAEB3B9)
    static let knob = Swatch(0xE8EAED)
    /// The dimmer behind a sheet.
    static let dimmer = Swatch(0x050607, alpha: 0.62)
    /// The timeline zoom slider's track, a touch lighter than the others.
    static let zoomTrack = Swatch(0x26292E)
    /// Empty thumbnail wells in the media browser.
    static let thumbnailWell = Swatch(0x1F2328)
    /// The music note in the media browser.
    static let musicIcon = Swatch(0x8FA3CF)
    /// The viewer canvas before there's a picture.
    static let canvas = Swatch(0x131518)
    /// The cut-out person in the viewer's layout preview.
    static let cutoutFigure = Swatch(0x3E5570)

    // MARK: - Timeline clips

    /// Fill, border and label colours for each kind of clip.
    struct ClipStyle {
        var fill: Swatch
        var border: Swatch
        var label: Swatch
        /// Waveform or placeholder strokes inside the clip.
        var detail: Swatch
    }

    static let cameraClip = ClipStyle(fill: Swatch(0x18212C), border: Swatch(0x3E5570), label: text, detail: Swatch(0x2A3A4E))
    static let screenClip = ClipStyle(fill: Swatch(0x141B25), border: Swatch(0x2E3E52), label: text, detail: Swatch(0x223043))
    static let brollClip = ClipStyle(fill: Swatch(0x1D1C2B), border: Swatch(0x4A4870), label: text, detail: Swatch(0x302E4A))
    static let textClip = ClipStyle(fill: Swatch(0x3A3322), border: Swatch(0x8A7440), label: Swatch(0xE6CF98), detail: Swatch(0x8A7440))
    static let graphicClip = ClipStyle(fill: Swatch(0x1E3A36), border: Swatch(0x2F6F66), label: Swatch(0x9DD8CC), detail: Swatch(0x9DD8CC))
    static let solidClip = ClipStyle(fill: Swatch(0x202328), border: Swatch(0x3A3F45), label: textSecondary, detail: Swatch(0x3A3F45))
    static let voiceClip = ClipStyle(fill: Swatch(0x13201A), border: Swatch(0x24402F), label: Swatch(0x9CCFB0), detail: Swatch(0x5E9C77))
    static let musicClip = ClipStyle(fill: Swatch(0x161B2A), border: Swatch(0x27304A), label: Swatch(0xA9B8DA), detail: Swatch(0x8FA3CF))
    static let sfxClip = ClipStyle(fill: Swatch(0x3A2A20), border: Swatch(0x8A5A3C), label: Swatch(0xE0B08A), detail: Swatch(0xE0B08A))

    /// Small labels drawn over thumbnails ("PiP right · cutout").
    static let badge = Swatch(0x0C0D0F, alpha: 0.75)
    static let transitionChip = Swatch(0xE8EAED)
    static let linkHighlight = Swatch(0xFFB224, alpha: 0.45)
    static let marqueeFill = Swatch(0xFFB224, alpha: 0.08)
    static let inOutFill = Swatch(0xFFB224, alpha: 0.07)
    static let gapFill = Swatch(0x111315)
    static let dropTarget = Swatch(0xFFB224, alpha: 0.16)

    // MARK: - Sizes

    enum Metrics {
        static let topBarHeight: CGFloat = 48
        static let mediaPanelWidth: CGFloat = 300
        static let inspectorWidth: CGFloat = 330
        static let transportHeight: CGFloat = 46
        static let timelineToolbarHeight: CGFloat = 36
        static let rulerHeight: CGFloat = 24
        static let statusBarHeight: CGFloat = 26
        static let trackHeaderWidth: CGFloat = 112
        static let trackGap: CGFloat = 3
        /// Points either side of the line between two track headers that
        /// grab it to change the track's height.
        static let trackResizeGrab: CGFloat = 5
        static let tracksTopPadding: CGFloat = 3
        static let clipCornerRadius: CGFloat = 4
        static let playheadHeadWidth: CGFloat = 11
        static let playheadHeadHeight: CGFloat = 10
        static let playheadWidth: CGFloat = 1.5
        /// Pixels either side of a clip edge that grab the edge, not the body.
        static let edgeGrab: CGFloat = 6
        /// Snapping reaches this many pixels.
        static let snapDistance: CGFloat = 8
        /// The default split between the workspace and the timeline, from the design.
        static let workspaceHeight: CGFloat = 524
        static let minimumTimelineHeight: CGFloat = 200
        static let minimumWorkspaceHeight: CGFloat = 260
    }

    /// Track heights by lane, from the design.
    enum TrackHeight {
        static let transcript: CGFloat = 18
        static let text: CGFloat = 24
        static let graphics: CGFloat = 32
        static let video: CGFloat = 48
        static let broll: CGFloat = 40
        static let voice: CGFloat = 40
        static let music: CGFloat = 30
        static let sfx: CGFloat = 20
        static let audio: CGFloat = 36
    }

    // MARK: - Type

    enum Fonts {
        static func ui(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
            NSFont.systemFont(ofSize: size, weight: weight)
        }

        /// Digits that don't jitter as they change, for timecode.
        static func digits(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
            NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
        }
    }
}

/// A theme colour usable from AppKit, Core Graphics and SwiftUI.
struct Swatch: Equatable {
    let hex: UInt32
    let alpha: CGFloat

    init(_ hex: UInt32, alpha: CGFloat = 1) {
        self.hex = hex
        self.alpha = alpha
    }

    var red: CGFloat { CGFloat((hex >> 16) & 0xFF) / 255 }
    var green: CGFloat { CGFloat((hex >> 8) & 0xFF) / 255 }
    var blue: CGFloat { CGFloat(hex & 0xFF) / 255 }

    var ns: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }
    var cg: CGColor { CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }
    var color: Color { Color(.sRGB, red: Double(red), green: Double(green), blue: Double(blue), opacity: Double(alpha)) }

    func opacity(_ value: CGFloat) -> Swatch { Swatch(hex, alpha: alpha * value) }
}

extension Font {
    /// The design's system type at an exact point size.
    static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
}
