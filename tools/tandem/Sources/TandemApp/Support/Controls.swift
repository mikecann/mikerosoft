import SwiftUI

/// The design's slider: a 3 pt track, a light fill and an 11 pt knob.
/// Reports when a drag starts and ends so callers can preview while
/// dragging and commit once.
struct GraphiteSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var track: Swatch = Theme.sliderTrack
    var fill: Swatch = Theme.sliderFill
    /// Fill from zero in the middle, for values that go both ways.
    var bipolar = false
    var onEditingChanged: (Bool) -> Void = { _ in }
    @State private var editing = false

    private func fraction(_ v: Double) -> Double {
        guard range.upperBound > range.lowerBound else { return 0 }
        return min(max((v - range.lowerBound) / (range.upperBound - range.lowerBound), 0), 1)
    }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let knob: CGFloat = 11
            let usable = max(width - knob, 1)
            let position = CGFloat(fraction(value)) * usable
            let origin = bipolar ? CGFloat(fraction(min(max(0, range.lowerBound), range.upperBound))) * usable : 0
            ZStack(alignment: .leading) {
                Capsule().fill(track.color).frame(height: 3)
                    .padding(.horizontal, knob / 2)
                Rectangle().fill(fill.color)
                    .frame(width: abs(position - origin), height: 3)
                    .offset(x: knob / 2 + min(position, origin))
                Circle().fill(Theme.knob.color)
                    .frame(width: knob, height: knob)
                    .offset(x: position)
                    .shadow(color: .black.opacity(0.3), radius: 1, y: 0.5)
            }
            .frame(height: geometry.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        if !editing {
                            editing = true
                            onEditingChanged(true)
                        }
                        let fraction = min(max((gesture.location.x - knob / 2) / usable, 0), 1)
                        value = range.lowerBound + Double(fraction) * (range.upperBound - range.lowerBound)
                    }
                    .onEnded { _ in
                        editing = false
                        onEditingChanged(false)
                    }
            )
        }
        .frame(height: 14)
    }
}

/// The design's switch: 28 by 16, amber when on.
struct GraphiteSwitch: View {
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule().fill(isOn ? Theme.amber.color : Theme.segmentSelected.color)
                Circle().fill(isOn ? Theme.onAmber.color : Theme.textMuted.color)
                    .frame(width: 12, height: 12)
                    .padding(.horizontal, 2)
            }
            .frame(width: 28, height: 16)
            .animation(.easeOut(duration: 0.12), value: isOn)
        }
        .buttonStyle(.plain)
    }
}

/// The layout control: equal segments on a dark track.
struct GraphiteSegmented<Option: Hashable>: View {
    let options: [Option]
    let selected: Option?
    let title: (Option) -> String
    let action: (Option) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options, id: \.self) { option in
                let isSelected = option == selected
                Button {
                    action(option)
                } label: {
                    Text(title(option))
                        .font(.ui(11.5, isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? Theme.text.color : Theme.textSecondary.color)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 5).fill(isSelected ? Theme.segmentSelected.color : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.field.color))
    }
}

/// A section of the inspector with a bold title and a divider below.
struct InspectorSection<Content: View, Accessory: View>: View {
    let title: String
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(title)
                    .font(.ui(12, .bold))
                    .foregroundStyle(Theme.text.color)
                Spacer()
                accessory()
            }
            content()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border.color).frame(height: 1) }
    }
}

extension InspectorSection where Accessory == EmptyView {
    init(title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.accessory = { EmptyView() }
        self.content = content
    }
}

/// Label, slider and value, the inspector's standard row. Drags preview
/// through `onPreview` and commit once through `onCommit`.
struct SliderRow: View {
    let label: String
    let value: Double
    let range: ClosedRange<Double>
    var bipolar = false
    /// Room for the value text; wide values like "−31.0 dB" need more.
    var valueWidth: CGFloat = 48
    var format: (Double) -> String = { String(format: "%.0f", $0) }
    var parse: (String) -> Double? = { Double($0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "%", with: "")) }
    var onPreview: (Double?) -> Void = { _ in }
    let onCommit: (Double) -> Void
    @State private var draft: Double?
    @State private var typing = false
    @State private var typed = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.ui(12))
                .foregroundStyle(Theme.textMuted.color)
                .frame(width: 86, alignment: .leading)
                .lineLimit(1)
            GraphiteSlider(
                value: Binding(get: { draft ?? value }, set: { draft = $0; onPreview($0) }),
                range: range,
                bipolar: bipolar,
                onEditingChanged: { editing in
                    if !editing, let final = draft {
                        draft = nil
                        onPreview(nil)
                        if final != value { onCommit(final) }
                    }
                }
            )
            if typing {
                TextField("", text: $typed)
                    .textFieldStyle(.plain)
                    .font(.ui(12))
                    .foregroundStyle(Theme.text.color)
                    .multilineTextAlignment(.trailing)
                    .frame(width: valueWidth)
                    .focused($fieldFocused)
                    .onSubmit(finishTyping)
                    .onChange(of: fieldFocused) { _, focused in if !focused { finishTyping() } }
            } else {
                Text(format(draft ?? value))
                    .font(.ui(12).monospacedDigit())
                    .foregroundStyle(Theme.text.color)
                    .frame(width: valueWidth, alignment: .trailing)
                    .lineLimit(1)
                    .onTapGesture(count: 2) {
                        typed = format(value)
                        typing = true
                        fieldFocused = true
                    }
                    .help("Double-click to type a value")
            }
        }
    }

    private func finishTyping() {
        guard typing else { return }
        typing = false
        if let number = parse(typed) {
            let clamped = min(max(number, range.lowerBound), range.upperBound)
            if clamped != value { onCommit(clamped) }
        }
    }
}

/// A plain row: muted label on the left, value on the right.
struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.ui(12))
                .foregroundStyle(Theme.textMuted.color)
                .frame(width: 86, alignment: .leading)
            Text(value)
                .font(.ui(12))
                .foregroundStyle(Theme.text.color)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Outlined small button, like "Undo" and "Fit" in the design.
struct OutlineButton: View {
    let title: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.ui(11.5))
                .foregroundStyle(Theme.text.color)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.buttonBorder.color, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
