import SwiftUI
import TandemCore

/// The colour mixer, Lightroom style: a row of eight swatches, and the
/// hue, saturation and luminance of the one picked. Swatches with changes
/// get a dot.
struct ColourMixerPanel: View {
    let values: [String: ParamValue]
    let selected: String
    let select: (String) -> Void
    /// The diamond (or its gap) after a slider, by parameter key.
    let accessory: (String) -> AnyView?
    /// A parameter key, its new value and the undo menu's name for it.
    let commit: (String, Double, String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 0) {
                ForEach(ColourSection.mixerColours, id: \.self) { colour in
                    MixerSwatch(
                        colour: colour,
                        selected: colour == selected,
                        changed: ColourSummary.mixerChanged(colour, values),
                        help: help(colour)
                    ) { select(colour) }
                    .frame(maxWidth: .infinity)
                }
            }
            ForEach(ColourSliderSpec.mixer(selected), id: \.key) { spec in
                spec.row(section: .mixer, value: values[spec.key]?.number ?? 0, accessory: accessory(spec.key)) { value in
                    commit(spec.key, value, spec.undo)
                }
            }
        }
    }

    /// "Reds: saturation −8%", or what clicking does.
    private func help(_ colour: String) -> String {
        let plural = colour == "aqua" ? "Aquas" : colour.capitalized + "s"
        let changes = ColourSliderSpec.mixer(colour).compactMap { spec -> String? in
            let value = values[spec.key]?.number ?? 0
            return value == 0 ? nil : "\(spec.label.lowercased()) \(spec.format(value))"
        }
        return changes.isEmpty ? "\(plural): click to adjust them" : "\(plural): \(changes.joined(separator: ", "))"
    }
}

/// A round swatch: ringed when picked, dotted when its colour is changed.
struct MixerSwatch: View {
    let colour: String
    let selected: Bool
    let changed: Bool
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                ZStack {
                    Circle()
                        .strokeBorder(selected ? Theme.text.color : Color.clear, lineWidth: 1.5)
                        .frame(width: 26, height: 26)
                    Circle()
                        .fill(ColourTracks.hsb(ColourSection.mixerHues[colour] ?? 0, 0.78, 0.92))
                        .overlay(Circle().strokeBorder(Color.black.opacity(0.35), lineWidth: 0.5))
                        .frame(width: selected ? 19 : 18, height: selected ? 19 : 18)
                }
                Circle()
                    .fill(changed ? Theme.amber.color : Color.clear)
                    .frame(width: 4, height: 4)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
