import AppKit
import SwiftUI
import TandemCore

/// A section card's words, number, progress and colours, at the top of the
/// Video tab for `sectionCard` clips. Each change is one edit that patches
/// `content.graphic.props`; text fields commit on Return or when you click
/// away.
struct SectionCardSection: View {
    let model: EditorModel
    let clip: Clip
    let props: SectionCard.Props

    var body: some View {
        InspectorSection(title: "Section card", icon: Icons.sectionCard) {
            CardTextRow(
                label: "Title", icon: Icons.cardTitle, value: props.title, placeholder: "Methodology",
                help: "The big words, in Anton, upper case. Long titles wrap onto balanced lines."
            ) { commit(SectionCardEdits.set(clip, SectionCard.Key.title, text: $0, label: "Card title")) }
            CardTextRow(
                label: "Subtitle", icon: Icons.cardSubtitle, value: props.subtitle, placeholder: "Let's keep it fair",
                help: "The short line under the title, letter-spaced in the accent colour. Leave it empty for none."
            ) { commit(SectionCardEdits.set(clip, SectionCard.Key.subtitle, text: $0, label: "Card subtitle")) }
            HStack(spacing: 8) {
                RowLabel(title: "Number", icon: Icons.cardNumber)
                CardField(value: props.number, placeholder: "01", width: 44) {
                    commit(SectionCardEdits.set(clip, SectionCard.Key.number, text: $0, label: "Card number"))
                }
                .help("What the chip says, like 01. Leave it empty for no chip. As a whole number it's also this section's place in the progress bars.")
                Text("of").font(.ui(12)).foregroundStyle(Theme.textMuted.color)
                CardField(value: props.total > 0 ? String(props.total) : "", placeholder: "0", width: 36) {
                    commit(SectionCardEdits.total(clip, text: $0))
                }
                .help("How many sections there are, for the progress bars under the subtitle: a bar for each up to six, then one bar in proportion with a count like 3 / 14. 0 hides them.")
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                RowLabel(title: "Kicker", icon: Icons.cardKicker)
                GraphiteSegmented(
                    options: SectionCardEdits.kickers(current: props.kicker),
                    selected: props.kicker,
                    title: { $0.isEmpty ? "None" : $0 },
                    help: { kicker in
                        kicker.isEmpty ? "No words beside the number" : "Shows \(SectionCard.Props(number: props.number, total: props.total, kicker: kicker).kickerLine?.uppercased() ?? kicker.uppercased()) beside the number"
                    }
                ) { kicker in
                    commit(SectionCardEdits.set(clip, SectionCard.Key.kicker, text: kicker, label: "Card kicker"))
                }
            }
            ColoursRow(props: props) { key, colour, label in
                commit(SectionCardEdits.colour(clip, key, colour, label: label))
            } reset: {
                commit(SectionCardEdits.resetColours(clip))
            }
        }
    }

    private func commit(_ batch: EditBatch?) {
        guard let batch else { return }
        model.apply(batch)
    }
}

/// An icon and a muted label, the width of the inspector's labels.
private struct RowLabel: View {
    let title: String
    let icon: String

    var body: some View {
        HStack(spacing: 5) {
            PanelIcon(name: icon, size: 10)
            Text(title)
                .font(.ui(12))
                .foregroundStyle(Theme.textMuted.color)
        }
        .frame(width: 86, alignment: .leading)
    }
}

private struct CardTextRow: View {
    let label: String
    let icon: String
    let value: String
    let placeholder: String
    let help: String
    let commit: (String) -> Void

    var body: some View {
        HStack(spacing: 8) {
            RowLabel(title: label, icon: icon)
            CardField(value: value, placeholder: placeholder, width: nil, commit: commit)
        }
        .help(help)
    }
}

/// A text field in the inspector's style that commits on Return or when
/// it loses focus, and follows the clip when it isn't being edited.
private struct CardField: View {
    let value: String
    let placeholder: String
    let width: CGFloat?
    let commit: (String) -> Void
    @State private var draft = ""
    @FocusState private var editing: Bool

    var body: some View {
        TextField(placeholder, text: $draft)
            .textFieldStyle(.plain)
            .font(.ui(12.5))
            .foregroundStyle(Theme.text.color)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .frame(width: width)
            .frame(maxWidth: width == nil ? .infinity : nil)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.field.color))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.fieldBorder.color, lineWidth: 1))
            .focused($editing)
            .onAppear { draft = value }
            .onChange(of: value) { _, new in if !editing { draft = new } }
            .onChange(of: editing) { _, now in if !now { finish() } }
            .onSubmit(finish)
    }

    private func finish() {
        guard draft != value else { return }
        commit(draft)
    }
}

/// The accent (first band, chip, subtitle, lit bars), the other two bands
/// and the card, with a reset to Convex's colours.
private struct ColoursRow: View {
    let props: SectionCard.Props
    let change: (String, RGBA, String) -> Void
    let reset: () -> Void

    var body: some View {
        let colours = props.colors
        HStack(spacing: 8) {
            RowLabel(title: "Colours", icon: Icons.cardColours)
            swatch(colours.accent, SectionCard.Key.accent, "Card accent", "The first band, the chip, the subtitle and the lit bars. Convex yellow #F3B01C.")
            swatch(colours.band2, SectionCard.Key.band2, "Card band", "The second band. Convex red #EE342F.")
            swatch(colours.band3, SectionCard.Key.band3, "Card band", "The third band. Convex purple #8D2676.")
            swatch(colours.background, SectionCard.Key.background, "Card colour", "The card behind the words. #141418.")
            Spacer(minLength: 0)
            if colours != .convex {
                IconButton(symbol: Icons.reset, help: "Back to Convex's colours") { reset() }
            }
        }
    }

    private func swatch(_ value: RGBA, _ key: String, _ label: String, _ help: String) -> some View {
        ColorPicker("", selection: Binding(
            get: { Color(.sRGB, red: value.r, green: value.g, blue: value.b, opacity: 1) },
            set: { colour in
                guard let converted = NSColor(colour).usingColorSpace(.sRGB) else { return }
                let rgba = RGBA(r: Double(converted.redComponent), g: Double(converted.greenComponent), b: Double(converted.blueComponent))
                ColourCommitter.shared.schedule { change(key, rgba, label) }
            }
        ), supportsOpacity: false)
        .labelsHidden()
        .help(help)
    }
}

/// The section card's edit batches: merge patches on the clip's props.
/// Empty words and a zero total remove the prop, so the card leaves that
/// part out.
enum SectionCardEdits {
    static func patch(_ clip: Clip, _ fields: [String: JSONValue], label: String) -> EditBatch {
        EditBatch(label: label, commands: [
            .updateClip(clipID: clip.id, patch: .object(["content": .object(["graphic": .object(["props": .object(fields)])])]))
        ])
    }

    /// Sets a text prop, or removes it when `text` is empty. Nil when
    /// nothing changes.
    static func set(_ clip: Clip, _ key: String, text: String, label: String) -> EditBatch? {
        guard let props = SectionCard.props(of: clip) else { return nil }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let current: String
        switch key {
        case SectionCard.Key.title: current = props.title
        case SectionCard.Key.subtitle: current = props.subtitle
        case SectionCard.Key.number: current = props.number
        case SectionCard.Key.kicker: current = props.kicker
        default: return nil
        }
        guard value != current else { return nil }
        return patch(clip, [key: value.isEmpty ? .null : .string(value)], label: label)
    }

    /// Sets how many sections there are from typed text; 0 or nothing
    /// removes the progress bars.
    static func total(_ clip: Clip, text: String) -> EditBatch? {
        guard let props = SectionCard.props(of: clip) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let value = trimmed.isEmpty ? 0 : Int(trimmed), value >= 0, value <= 999, value != props.total else { return nil }
        return patch(clip, [SectionCard.Key.total: value == 0 ? .null : .number(Double(value))], label: "Card total")
    }

    /// Sets one colour; Convex's own colour removes the prop.
    static func colour(_ clip: Clip, _ key: String, _ colour: RGBA, label: String) -> EditBatch? {
        guard let props = SectionCard.props(of: clip) else { return nil }
        let defaults = SectionCard.Colors.convex
        let current: RGBA, standard: RGBA
        switch key {
        case SectionCard.Key.accent: (current, standard) = (props.colors.accent, defaults.accent)
        case SectionCard.Key.band2: (current, standard) = (props.colors.band2, defaults.band2)
        case SectionCard.Key.band3: (current, standard) = (props.colors.band3, defaults.band3)
        case SectionCard.Key.background: (current, standard) = (props.colors.background, defaults.background)
        default: return nil
        }
        guard colour.hexString != current.hexString else { return nil }
        return patch(clip, [key: colour.hexString == standard.hexString ? .null : ParamValue.color(colour).json], label: label)
    }

    static func resetColours(_ clip: Clip) -> EditBatch? {
        guard let props = SectionCard.props(of: clip), props.colors != .convex else { return nil }
        let keys = [SectionCard.Key.accent, SectionCard.Key.band2, SectionCard.Key.band3, SectionCard.Key.background]
        return patch(clip, Dictionary(uniqueKeysWithValues: keys.map { ($0, JSONValue.null) }), label: "Card colours")
    }

    /// The kicker choices: none, Section and Tip, and the card's own when
    /// it's something else.
    static func kickers(current: String) -> [String] {
        let standard = ["", "Section", "Tip"]
        return standard.contains(current) ? standard : standard + [current]
    }
}
