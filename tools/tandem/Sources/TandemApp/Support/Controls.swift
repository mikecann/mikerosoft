import AppKit
import SwiftUI

/// The design's slider: a 3 pt track, a light fill and an 11 pt knob, or a
/// gradient track for colour controls (blue to amber for temperature, grey
/// to colour for saturation). Reports when a drag starts and ends so
/// callers can preview while dragging and commit once.
///
/// Grabbing the knob moves it from where it is (Option for fine steps);
/// pressing the track jumps to the pointer. Double-clicking the knob puts
/// `defaultValue` back.
struct GraphiteSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var track: Swatch = Theme.sliderTrack
    var fill: Swatch = Theme.sliderFill
    /// Fill from zero in the middle, for values that go both ways.
    var bipolar = false
    /// Colours along the track, left to right, in place of the track and
    /// fill.
    var gradient: [Color]? = nil
    /// What a double-click puts back; nil for nothing.
    var defaultValue: Double? = nil
    var onEditingChanged: (Bool) -> Void = { _ in }
    @State private var editing = false
    /// True when the drag started on the knob, so it moves from there.
    @State private var grabbedKnob = false
    @State private var lastX: CGFloat = 0
    @State private var lastClick: TimeInterval = 0

    static let knob: CGFloat = 11

    private func fraction(_ v: Double) -> Double {
        guard range.upperBound > range.lowerBound else { return 0 }
        return min(max((v - range.lowerBound) / (range.upperBound - range.lowerBound), 0), 1)
    }

    var body: some View {
        GeometryReader { geometry in
            let knob = Self.knob
            let usable = max(geometry.size.width - knob, 1)
            let position = CGFloat(fraction(value)) * usable
            let zero = CGFloat(fraction(min(max(0, range.lowerBound), range.upperBound))) * usable
            ZStack(alignment: .leading) {
                if let gradient {
                    Capsule()
                        .fill(LinearGradient(colors: gradient, startPoint: .leading, endPoint: .trailing))
                        .overlay(Capsule().strokeBorder(Color.black.opacity(0.35), lineWidth: 0.5))
                        .frame(height: 5)
                        .padding(.horizontal, knob / 2 - 1)
                    if bipolar {
                        // Where "no change" is.
                        Rectangle().fill(Color.black.opacity(0.45))
                            .frame(width: 1, height: 9)
                            .offset(x: knob / 2 + zero - 0.5)
                    }
                } else {
                    Capsule().fill(track.color).frame(height: 3)
                        .padding(.horizontal, knob / 2)
                    let origin = bipolar ? zero : 0
                    Rectangle().fill(fill.color)
                        .frame(width: abs(position - origin), height: 3)
                        .offset(x: knob / 2 + min(position, origin))
                }
                Circle().fill(Theme.knob.color)
                    .overlay(Circle().strokeBorder(Color.black.opacity(gradient == nil ? 0 : 0.4), lineWidth: 0.5))
                    .frame(width: knob, height: knob)
                    .offset(x: position)
                    .shadow(color: .black.opacity(0.3), radius: 1, y: 0.5)
            }
            .frame(height: geometry.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        let span = range.upperBound - range.lowerBound
                        if !editing {
                            editing = true
                            grabbedKnob = abs(gesture.startLocation.x - (position + knob / 2)) <= knob / 2 + 3
                            lastX = gesture.startLocation.x
                            onEditingChanged(true)
                        }
                        if grabbedKnob {
                            let fine = NSEvent.modifierFlags.contains(.option) ? 0.1 : 1
                            let moved = Double((gesture.location.x - lastX) / usable) * span * fine
                            lastX = gesture.location.x
                            value = min(max(value + moved, range.lowerBound), range.upperBound)
                        } else {
                            let f = min(max((gesture.location.x - knob / 2) / usable, 0), 1)
                            value = range.lowerBound + Double(f) * span
                        }
                    }
                    .onEnded { gesture in
                        editing = false
                        let now = ProcessInfo.processInfo.systemUptime
                        let click = abs(gesture.translation.width) < 2 && abs(gesture.translation.height) < 2
                        if click, grabbedKnob, let defaultValue, now - lastClick < NSEvent.doubleClickInterval {
                            value = defaultValue
                            lastClick = 0
                        } else {
                            lastClick = click ? now : 0
                        }
                        onEditingChanged(false)
                    }
            )
        }
        .frame(height: 14)
    }
}

/// A number you drag left or right to change (Option for fine steps,
/// Shift for big ones), or click to type into. The inspector's values.
struct ScrubbableNumber: View {
    let value: Double
    let range: ClosedRange<Double>
    var width: CGFloat = 48
    var alignment: Alignment = .trailing
    var fontSize: CGFloat = 12
    /// How much a point of dragging changes the value; nil crosses the
    /// range in 200 points.
    var perPoint: Double? = nil
    let format: (Double) -> String
    let parse: (String) -> Double?
    var help: String? = nil
    /// Drawn faint, for a value that changes nothing.
    var dimmed = false
    /// While dragging, each new value.
    var onScrub: (Double) -> Void = { _ in }
    /// The drag ended: keep what it reached.
    var onScrubEnded: () -> Void = {}
    /// A value typed in, not yet clamped.
    let onType: (Double) -> Void
    @State private var scrubbed: Double?
    @State private var lastX: CGFloat = 0
    @State private var typing = false
    @State private var text = ""
    @State private var hovering = false
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if typing {
                TextField("", text: $text)
                    .textFieldStyle(.plain)
                    .font(.ui(fontSize).monospacedDigit())
                    .foregroundStyle(Theme.text.color)
                    .multilineTextAlignment(alignment == .leading ? .leading : (alignment == .center ? .center : .trailing))
                    .focused($focused)
                    .onAppear { focused = true }
                    .onSubmit(finishTyping)
                    .onExitCommand { typing = false }
                    .onChange(of: focused) { _, now in if !now { finishTyping() } }
            } else {
                Text(format(value))
                    .font(.ui(fontSize).monospacedDigit())
                    .foregroundStyle(dimmed && scrubbed == nil ? Theme.textFaint.color : Theme.text.color)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 3)
                    .padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 4).fill(hovering || scrubbed != nil ? Theme.field.color : .clear))
                    .contentShape(Rectangle())
                    .onHover { hovering = $0 }
                    .pointerStyle(.columnResize)
                    .gesture(scrub)
                    .tip(ifAny: help)
            }
        }
        .frame(width: width, alignment: alignment)
    }

    private var scrub: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { gesture in
                if scrubbed == nil, abs(gesture.translation.width) < 2 {
                    lastX = gesture.location.x
                    return
                }
                let flags = NSEvent.modifierFlags
                let scale = flags.contains(.option) ? 0.1 : (flags.contains(.shift) ? 10 : 1)
                let step = perPoint ?? (range.upperBound - range.lowerBound) / 200
                let next = (scrubbed ?? value) + Double(gesture.location.x - lastX) * step * scale
                lastX = gesture.location.x
                let clamped = min(max(next, range.lowerBound), range.upperBound)
                scrubbed = clamped
                onScrub(clamped)
            }
            .onEnded { _ in
                if scrubbed != nil {
                    scrubbed = nil
                    onScrubEnded()
                } else {
                    text = format(value)
                    typing = true
                }
            }
    }

    private func finishTyping() {
        guard typing else { return }
        typing = false
        if let number = parse(text) { onType(number) }
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

/// A small symbol button, like a section's reset arrow.
struct IconButton: View {
    let symbol: String
    let help: String
    var size: CGFloat = 10
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(enabled ? Theme.textMuted.color : Theme.textFainter.color.opacity(0.6))
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .tip(help)
    }
}

/// The layout control: equal segments on a dark track, each with an
/// optional icon over its title, and an amber dot on a segment that
/// `marked` picks out.
struct GraphiteSegmented<Option: Hashable>: View {
    let options: [Option]
    let selected: Option?
    let title: (Option) -> String
    var icon: ((Option) -> String)? = nil
    var help: ((Option) -> String)? = nil
    var marked: ((Option) -> Bool)? = nil
    let action: (Option) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options, id: \.self) { option in
                let isSelected = option == selected
                Button {
                    action(option)
                } label: {
                    VStack(spacing: 3) {
                        if let icon {
                            Image(systemName: icon(option))
                                .font(.system(size: 13, weight: .regular))
                        }
                        Text(title(option))
                            .font(.ui(icon == nil ? 11.5 : 10.5, isSelected ? .semibold : .regular))
                            .lineLimit(1)
                    }
                    .foregroundStyle(isSelected ? Theme.text.color : Theme.textSecondary.color)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, icon == nil ? 4 : 5)
                    .background(RoundedRectangle(cornerRadius: 5).fill(isSelected ? Theme.segmentSelected.color : .clear))
                    .overlay(alignment: .topTrailing) {
                        if marked?(option) == true {
                            Circle().fill(Theme.amber.color).frame(width: 5, height: 5).padding(5)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .tip(help?(option) ?? "")
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.field.color))
    }
}

/// A section of the inspector with a bold title (and its icon) and a
/// divider below.
struct InspectorSection<Content: View, Accessory: View>: View {
    let title: String
    var icon: String? = nil
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                if let icon { PanelIcon(name: icon) }
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
    init(title: String, icon: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.icon = icon
        self.accessory = { EmptyView() }
        self.content = content
    }
}

/// Label, slider and value, the inspector's standard row. Drags preview
/// through `onPreview` and commit once through `onCommit`. The value can be
/// dragged left and right too, or clicked to type; double-clicking the
/// knob or the label goes back to `defaultValue`. Labels are never cut
/// short: a long one takes room from the slider. Tooltips come from
/// `help`; without it the row adds none, so one set around it shows.
struct SliderRow: View {
    let label: String
    let value: Double
    let range: ClosedRange<Double>
    var bipolar = false
    /// Room for the value text; wide values like "−31.0 dB" need more.
    var valueWidth: CGFloat = 48
    var format: (Double) -> String = { String(format: "%.0f", $0) }
    var parse: (String) -> Double? = SliderRow.plainNumber
    /// What double-clicking the knob puts back. Nil means 0 for a range
    /// that goes both ways, otherwise nothing.
    var defaultValue: Double? = nil
    /// Colours along the track, for colour controls.
    var gradient: [Color]? = nil
    /// What the control does, shown when the pointer rests on it.
    var help: String? = nil
    /// Committed values are multiples of this.
    var step: Double? = nil
    /// Draws the value faint while it's at `defaultValue`, so the ones
    /// that change something stand out.
    var dimsDefault = false
    var onPreview: (Double?) -> Void = { _ in }
    /// Something after the value, like a keyframe diamond.
    var accessory: AnyView? = nil
    /// Draws the label in amber, for a value set here rather than taken
    /// from somewhere else (a title's preset).
    var marked = false
    let onCommit: (Double) -> Void
    @State private var draft: Double?

    static let labelWidth: CGFloat = 86

    /// A number in text, allowing a "−" minus sign, a leading "+" and units.
    static func plainNumber(_ text: String) -> Double? {
        let cleaned = text.replacingOccurrences(of: "−", with: "-").filter { "-+0123456789.".contains($0) }
        return Double(cleaned.hasPrefix("+") ? String(cleaned.dropFirst()) : cleaned)
    }

    private var resetValue: Double? {
        if let defaultValue { return defaultValue }
        return bipolar && range.contains(0) ? 0 : nil
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.ui(12))
                .foregroundStyle(marked ? Theme.amber.color : Theme.textMuted.color)
                .fixedSize()
                .frame(minWidth: Self.labelWidth, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { if let resetValue { commit(resetValue) } }
                .tip(ifAny: help.map { [$0, resetHint].compactMap { $0 }.joined(separator: " ") })
            GraphiteSlider(
                value: Binding(get: { draft ?? value }, set: { draft = $0; onPreview($0) }),
                range: range,
                bipolar: bipolar,
                gradient: gradient,
                defaultValue: resetValue,
                onEditingChanged: { editing in if !editing { finish() } }
            )
            .tip(ifAny: help.map { [$0, resetHint].compactMap { $0 }.joined(separator: " ") })
            ScrubbableNumber(
                value: draft ?? value, range: range, width: valueWidth,
                format: format, parse: parse,
                help: help.map { "\($0) Drag the number left or right, or click it to type." },
                dimmed: dimsDefault && draft == nil && resetValue == value,
                onScrub: { draft = $0; onPreview($0) },
                onScrubEnded: finish,
                onType: { commit($0) }
            )
            if let accessory { accessory }
        }
    }

    private var resetHint: String? {
        resetValue.map { "Double-click to go back to \(format($0))." }
    }

    private func finish() {
        guard let final = draft else { return }
        draft = nil
        onPreview(nil)
        commit(final)
    }

    private func commit(_ raw: Double) {
        var v = min(max(raw, range.lowerBound), range.upperBound)
        if let step, step > 0 { v = min(max((v / step).rounded() * step, range.lowerBound), range.upperBound) }
        if v != value { onCommit(v) }
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
