import AppKit
import SwiftUI
import TandemCore

/// SF Symbols for the app's tabs, sections, effects and menu items, kept
/// in one place so the same thing always gets the same picture. Small
/// icons beside words make the panels quicker to scan.
enum Icons {
    static func tab(_ tab: InspectorTab) -> String {
        switch tab {
        case .video: return "film"
        case .colour: return "camera.filters"
        case .audio: return "waveform"
        case .info: return "info.circle"
        case .activity: return "clock.arrow.circlepath"
        }
    }

    static func layout(_ preset: LayoutPreset) -> String {
        switch preset {
        case .full: return "rectangle.inset.filled"
        case .pipRight: return "rectangle.inset.bottomright.filled"
        case .pipLeft: return "rectangle.inset.bottomleft.filled"
        case .split: return "rectangle.split.2x1.fill"
        case .fill: return "arrow.up.left.and.arrow.down.right"
        }
    }

    /// An effect by its registry type; effects from packs get sparkles.
    static func effect(_ type: String) -> String {
        switch type {
        case "colorAdjust": return "slider.horizontal.3"
        case "colorWheels": return "scope"
        case "hsl": return "paintpalette"
        case "vignette": return "circle.dashed"
        case "sharpen": return "triangle.lefthalf.filled"
        case "lut": return "cube"
        case "dropShadow": return "shadow"
        case "border": return "square.dashed"
        case "roundedCorners": return "app"
        case "blur": return "drop.halffull"
        case "pixelate": return "square.grid.3x3.fill"
        case "pitchShift": return "tuningfork"
        default: return "sparkles"
        }
    }

    // Inspector sections.
    static let layoutSection = "rectangle.3.group"
    static let cutout = "person.crop.rectangle"
    static let crop = "crop"
    static let text = "textformat"
    static let animation = "diamond"
    static let level = "speaker.wave.2"
    static let fades = "chart.line.uptrend.xyaxis"
    static let voiceIsolation = "waveform.badge.mic"
    /// The project's speech level, in the Audio tab.
    static let speechLevel = "person.wave.2"
    static let effects = "sparkles"
    static let look = "camera.filters"
    static let clipOnly = "film"
    static let clip = "film.stack"
    static let media = "doc"
    static let transition = "arrow.left.arrow.right"
    static let project = "film"
    static let keys = "keyboard"
    static let selectAClip = "cursorarrow.click.2"

    // The Colour tab.
    /// What the grade applies to: every clip of the take, or this one.
    static let wholeTake = "film.stack"
    static let thisClip = "film"
    /// A section's reset arrow.
    static let reset = "arrow.counterclockwise"
    static let expanded = "chevron.down"
    static let collapsed = "chevron.right"
    static let otherColourEffects = "sparkles"
    static let lutFile = "doc"
    static let clearFile = "xmark.circle.fill"

    /// A Colour tab section. Sections backed by one effect type use that
    /// effect's icon; Light and Colour share one, so they get their own.
    static func colourSection(_ section: ColourSection) -> String {
        switch section {
        case .light: return "sun.max"
        case .colour: return "thermometer.medium"
        default: return effect(section.effectType)
        }
    }

    /// A command's icon, for menus and buttons.
    static func command(_ command: EditorCommand) -> String? {
        switch command {
        case .playPause: return "playpause"
        case .shuttleReverse: return "backward"
        case .shuttleStop: return "stop"
        case .shuttleForward: return "forward"
        case .stepBack, .stepBackFive: return "backward.frame"
        case .stepForward, .stepForwardFive: return "forward.frame"
        case .goToStart: return "backward.end"
        case .goToEnd: return "forward.end"
        case .previousEdit: return "arrow.left.to.line"
        case .nextEdit: return "arrow.right.to.line"
        case .previousMarker: return "chevron.left"
        case .nextMarker: return "chevron.right"
        case .markIn: return "rectangle.lefthalf.filled"
        case .markOut: return "rectangle.righthalf.filled"
        case .clearIn, .clearOut, .clearInOut: return "xmark.circle"
        case .markClip: return "selection.pin.in.out"
        case .liftInOut: return "arrow.up.bin"
        case .extractInOut: return "scissors"
        case .bladeAtPlayhead: return "scissors"
        case .rippleTrimStart: return "arrow.left.to.line"
        case .rippleTrimEnd: return "arrow.right.to.line"
        case .lift: return "trash"
        case .rippleDelete: return "delete.backward"
        case .nudgeLeft, .nudgeLeftFive: return "arrow.left"
        case .nudgeRight, .nudgeRightFive: return "arrow.right"
        case .link: return "link"
        case .addMarker: return "bookmark"
        case .addTransition: return transition
        case .toggleKeyframe: return animation
        case .previousKeyframe: return "chevron.left"
        case .nextKeyframe: return "chevron.right"
        case .addVideoTrack: return "plus.rectangle"
        case .addAudioTrack: return "waveform.badge.plus"
        case .layoutFull: return layout(.full)
        case .layoutPipRight: return layout(.pipRight)
        case .layoutPipLeft: return layout(.pipLeft)
        case .layoutSplit: return layout(.split)
        case .selectAll: return "checkmark.circle"
        case .deselectAll: return "circle.dashed"
        case .selectForward: return "arrow.right.circle"
        case .zoomIn: return "plus.magnifyingglass"
        case .zoomOut: return "minus.magnifyingglass"
        case .zoomToFit: return "arrow.up.left.and.arrow.down.right"
        case .toggleSnapping: return "arrow.right.and.line.vertical.and.arrow.left"
        case .toggleLinkedSelection: return "link"
        case .toggleRipple: return "arrow.right.to.line"
        case .toggleTranscriptLane: return "text.bubble"
        case .toolSelect: return "cursorarrow"
        case .toolBlade: return "scissors"
        case .toolRippleTrim: return "arrow.left.to.line"
        case .toolRoll: return "arrow.left.arrow.right"
        case .toolSlip: return "arrow.left.and.right"
        case .toolSlide: return "arrow.left.and.line.vertical.and.arrow.right"
        case .toggleSafeMargins: return "rectangle.dashed"
        case .toggleProxy: return "bolt.horizontal"
        case .undo: return "arrow.uturn.backward"
        case .redo: return "arrow.uturn.forward"
        case .save: return "square.and.arrow.down"
        case .saveVersion: return "doc.on.doc"
        case .export: return "square.and.arrow.up"
        case .newProject: return "plus.square"
        case .openProject: return "folder"
        }
    }

    /// A symbol sized for menu items, or nil if the name is unknown.
    static func menuImage(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .regular))
    }
}

/// A symbol at the size the panels use beside 12 pt text.
struct PanelIcon: View {
    let name: String
    var size: CGFloat = 11
    var color: Color = Theme.textMuted.color

    var body: some View {
        Image(systemName: name)
            .font(.system(size: size, weight: .medium))
            .foregroundStyle(color)
            .frame(width: size + 5)
    }
}
