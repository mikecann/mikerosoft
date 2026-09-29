import AppKit
import SwiftUI
import TandemCore

/// Shadows, midtones and highlights wheels side by side. Each has a puck
/// for colour (hue and amount), a brightness slider, and its numbers, which
/// can be dragged or typed like any other value in the inspector.
struct ColourWheelsPanel: View {
    let values: [String: ParamValue]
    /// The keyframe diamond for a wheel, when its values can animate.
    let diamond: (ColourWheels.Wheel) -> AnyView?
    /// New values and the undo menu's name for them.
    let commit: ([String: ParamValue], String) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ForEach(ColourWheels.Wheel.allCases, id: \.self) { wheel in
                ColourWheelColumn(
                    wheel: wheel,
                    hue: values[wheel.hueKey]?.number ?? 0,
                    amount: values[wheel.amountKey]?.number ?? 0,
                    brightness: values[wheel.brightnessKey]?.number ?? 0,
                    diamond: diamond(wheel),
                    commit: commit
                )
                .frame(maxWidth: .infinity)
            }
        }
    }
}

/// One wheel: its name, the wheel, its brightness and its numbers.
struct ColourWheelColumn: View {
    let wheel: ColourWheels.Wheel
    let hue: Double
    let amount: Double
    let brightness: Double
    let diamond: AnyView?
    let commit: ([String: ParamValue], String) -> Void
    @State private var colourDraft: (hue: Double, amount: Double)?
    @State private var brightnessDraft: Double?

    /// What the wheel does to the picture, in the words an editor uses.
    private var role: String {
        switch wheel {
        case .shadows: return "the shadows (lift)"
        case .midtones: return "the midtones (gamma)"
        case .highlights: return "the highlights (gain)"
        }
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 0) {
                Text(wheel.name)
                    .font(.ui(11.5))
                    .foregroundStyle(amount != 0 || brightness != 0 ? Theme.text.color : Theme.textMuted.color)
                    .fixedSize()
                if let diamond { diamond }
            }
            .frame(height: 18)
            ColourWheelView(
                hue: colourDraft?.hue ?? hue, amount: colourDraft?.amount ?? amount,
                help: "Drag anywhere in the wheel to tint \(role) towards a colour; the further out, the stronger. Option-drag for fine moves, double-click to reset."
            ) { newHue, newAmount in
                setColour(hue: newHue, amount: newAmount)
            }
            .frame(maxWidth: 96)
            HStack(spacing: 4) {
                ScrubbableNumber(
                    value: colourDraft?.amount ?? amount, range: 0...100, width: 34, alignment: .trailing, fontSize: 11,
                    format: { "\(Int($0.rounded()))%" }, parse: SliderRow.plainNumber,
                    help: "How strong the \(wheel.name.lowercased()) colour is. Drag or click to type.",
                    dimmed: (colourDraft?.amount ?? amount) == 0,
                    onScrub: { colourDraft = (hue, $0) },
                    onScrubEnded: finishColour,
                    onType: { value in setColour(hue: hue, amount: min(max(value, 0), 100)) }
                )
                ScrubbableNumber(
                    value: colourDraft?.hue ?? hue, range: -3600...3600, width: 36, alignment: .leading, fontSize: 11, perPoint: 1,
                    format: { "\(Int(ColourWheels.normalised($0.rounded())))°" }, parse: SliderRow.plainNumber,
                    help: "The \(wheel.name.lowercased()) colour's hue: 0° red, 60° yellow, 120° green, 180° cyan, 240° blue, 300° magenta. Drag or click to type.",
                    dimmed: (colourDraft?.amount ?? amount) == 0,
                    onScrub: { colourDraft = (ColourWheels.normalised($0), amount) },
                    onScrubEnded: finishColour,
                    onType: { value in setColour(hue: value, amount: amount) }
                )
            }
            HStack(spacing: 4) {
                GraphiteSlider(
                    value: Binding(get: { brightnessDraft ?? brightness }, set: { brightnessDraft = $0 }),
                    range: -100...100,
                    bipolar: true,
                    gradient: ColourTracks.brightness,
                    defaultValue: 0,
                    onEditingChanged: { editing in if !editing { finishBrightness() } }
                )
                .help("Brightness of \(role). Double-click the knob to reset.")
                ScrubbableNumber(
                    value: brightnessDraft ?? brightness, range: -100...100, width: 30, fontSize: 11,
                    format: ColourWheelColumn.signed, parse: SliderRow.plainNumber,
                    help: "Brightness of \(role). Drag or click to type.",
                    dimmed: (brightnessDraft ?? brightness) == 0,
                    onScrub: { brightnessDraft = $0 },
                    onScrubEnded: finishBrightness,
                    onType: { setBrightness($0) }
                )
            }
        }
    }

    static func signed(_ value: Double) -> String {
        let rounded = Int(value.rounded())
        return rounded == 0 ? "0" : (rounded < 0 ? "−\(-rounded)" : "+\(rounded)")
    }

    private func finishColour() {
        guard let draft = colourDraft else { return }
        colourDraft = nil
        setColour(hue: draft.hue, amount: draft.amount)
    }

    private func setColour(hue newHue: Double, amount newAmount: Double) {
        let h = ColourWheels.normalised(newHue.rounded())
        let a = min(max(newAmount, 0), 100).rounded()
        guard h != hue || a != amount else { return }
        commit([wheel.hueKey: .number(h), wheel.amountKey: .number(a)], "\(wheel.name) wheel")
    }

    private func finishBrightness() {
        guard let draft = brightnessDraft else { return }
        brightnessDraft = nil
        setBrightness(draft)
    }

    private func setBrightness(_ value: Double) {
        let clamped = min(max(value, -100), 100).rounded()
        guard clamped != brightness else { return }
        commit([wheel.brightnessKey: .number(clamped)], "\(wheel.name) brightness")
    }
}

/// A colour wheel laid out like a vectorscope, with a puck for the colour.
/// Dragging anywhere moves the puck from where it is, so small moves stay
/// small; Option makes them finer. Double-click puts it back in the middle.
struct ColourWheelView: View {
    let hue: Double
    let amount: Double
    let help: String
    let commit: (_ hue: Double, _ amount: Double) -> Void
    @State private var draft: (hue: Double, amount: Double)?
    @State private var puck: (x: Double, y: Double)?
    @State private var last: CGPoint = .zero
    @State private var lastClick: TimeInterval = 0

    static let ringWidth: CGFloat = 5

    /// How far from the centre amount 100 sits.
    static func reach(_ side: CGFloat) -> CGFloat {
        max(side / 2 - ringWidth - 6, 1)
    }

    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            let shown = draft ?? (hue, amount)
            Canvas { context, size in
                Self.draw(in: &context, size: size, hue: shown.hue, amount: shown.amount)
            }
            .frame(width: side, height: side)
            .contentShape(Circle())
            .gesture(drag(reach: Self.reach(side)))
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .aspectRatio(1, contentMode: .fit)
        .help(help)
    }

    private func drag(reach: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { gesture in
                if puck == nil {
                    puck = ColourWheels.puck(hue: hue, amount: amount)
                    last = gesture.startLocation
                }
                guard var position = puck else { return }
                let fine = NSEvent.modifierFlags.contains(.option) ? 0.25 : 1
                position.x += Double((gesture.location.x - last.x) / reach) * fine
                position.y -= Double((gesture.location.y - last.y) / reach) * fine
                last = gesture.location
                let distance = (position.x * position.x + position.y * position.y).squareRoot()
                if distance > 1 { position = (position.x / distance, position.y / distance) }
                puck = position
                if abs(gesture.translation.width) >= 1 || abs(gesture.translation.height) >= 1 {
                    draft = ColourWheels.hueAndAmount(x: position.x, y: position.y, keeping: hue)
                }
            }
            .onEnded { gesture in
                let now = ProcessInfo.processInfo.systemUptime
                let click = abs(gesture.translation.width) < 2 && abs(gesture.translation.height) < 2
                if click {
                    if now - lastClick < NSEvent.doubleClickInterval {
                        lastClick = 0
                        if hue != 0 || amount != 0 { commit(0, 0) }
                    } else {
                        lastClick = now
                    }
                } else if let draft {
                    let newAmount = draft.amount.rounded()
                    let newHue = newAmount == 0 ? hue : ColourWheels.normalised(draft.hue.rounded())
                    if newHue != hue || newAmount != amount { commit(newHue, newAmount) }
                }
                draft = nil
                puck = nil
            }
    }

    /// The ring of hues, a faint wash of them inside that strengthens
    /// towards the edge, a crosshair, and the puck.
    static func draw(in context: inout GraphicsContext, size: CGSize, hue: Double, amount: Double) {
        let side = min(size.width, size.height)
        let centre = CGPoint(x: size.width / 2, y: size.height / 2)
        let outer = CGRect(x: centre.x - side / 2, y: centre.y - side / 2, width: side, height: side)
        let inner = outer.insetBy(dx: ringWidth, dy: ringWidth)
        context.fill(Path(ellipseIn: outer), with: .conicGradient(ColourWheelArt.gradient, center: centre))
        context.fill(Path(ellipseIn: inner), with: .color(Color(white: 0.12)))
        context.drawLayer { layer in
            layer.fill(Path(ellipseIn: inner), with: .conicGradient(ColourWheelArt.gradient, center: centre))
            layer.blendMode = .destinationIn
            layer.fill(Path(ellipseIn: inner), with: .radialGradient(
                Gradient(colors: [.white.opacity(0), .white.opacity(0.42)]), center: centre, startRadius: 0, endRadius: inner.width / 2
            ))
        }
        context.stroke(Path(ellipseIn: inner), with: .color(.black.opacity(0.5)), lineWidth: 1)

        var cross = Path()
        let arm = inner.width / 2 - 2
        cross.move(to: CGPoint(x: centre.x - arm, y: centre.y))
        cross.addLine(to: CGPoint(x: centre.x + arm, y: centre.y))
        cross.move(to: CGPoint(x: centre.x, y: centre.y - arm))
        cross.addLine(to: CGPoint(x: centre.x, y: centre.y + arm))
        context.stroke(cross, with: .color(.white.opacity(0.1)), lineWidth: 1)
        context.fill(Path(ellipseIn: CGRect(x: centre.x - 1.5, y: centre.y - 1.5, width: 3, height: 3)), with: .color(.white.opacity(0.35)))

        let reach = reach(side)
        let p = ColourWheels.puck(hue: hue, amount: amount)
        let point = CGPoint(x: centre.x + CGFloat(p.x) * reach, y: centre.y - CGFloat(p.y) * reach)
        if amount > 0 {
            var line = Path()
            line.move(to: centre)
            line.addLine(to: point)
            context.stroke(line, with: .color(.white.opacity(0.45)), lineWidth: 1)
        }
        let knob: CGFloat = 10
        let puckRect = CGRect(x: point.x - knob / 2, y: point.y - knob / 2, width: knob, height: knob)
        let fill = amount > 0 ? ColourTracks.hsb(hue, min(1, 0.25 + amount / 60), 1) : Color(white: 0.85)
        context.fill(Path(ellipseIn: puckRect.insetBy(dx: -1, dy: -1)), with: .color(.black.opacity(0.45)))
        context.fill(Path(ellipseIn: puckRect), with: .color(fill))
        context.stroke(Path(ellipseIn: puckRect), with: .color(.white), lineWidth: 1.5)
    }
}

/// The wheel's colours: each hue where the wheel puts it. Conic gradients
/// run clockwise from the right on screen, the wheel anticlockwise.
enum ColourWheelArt {
    static let gradient: Gradient = {
        let stops = stride(from: 0.0, through: 360, by: 3).map { turn -> Gradient.Stop in
            let hue = ColourWheels.hue(wheelAngle: ColourWheels.normalised(360 - turn))
            return Gradient.Stop(color: ColourTracks.hsb(hue, 0.9, 0.95), location: turn / 360)
        }
        return Gradient(stops: stops)
    }()
}

/// One diamond for a group of parameters that change together, like a
/// wheel's hue, amount and brightness: animated when any of them is,
/// filled when any has a keyframe at the playhead. Clicking adds a
/// keyframe for all of them, or removes theirs at the playhead.
struct KeyframeGroupButton: View {
    let model: EditorModel
    let clip: Clip
    let parameters: [String]
    /// "Shadows wheel".
    let name: String

    var body: some View {
        let animated = parameters.contains { KeyframeEdits.isAnimated($0, in: clip) }
        let here = animated && !KeyframeEdits.parameters(in: clip, keyedAt: model.clipTime(of: clip), tolerance: model.keyframeTolerance, among: parameters).isEmpty
        Button {
            toggle(here: here, animated: animated)
        } label: {
            ZStack {
                DiamondShape().fill(here ? Theme.amber.color : Color.clear)
                DiamondShape().stroke(animated ? Theme.amber.color : Theme.textFaint.color, lineWidth: 1.2)
            }
            .frame(width: 9, height: 9)
            .frame(width: 16, height: 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(here ? "Remove the \(name.lowercased()) keyframe at the playhead" : (animated ? "Add a \(name.lowercased()) keyframe at the playhead" : "Animate the \(name.lowercased()): add a keyframe at the playhead"))
    }

    private func toggle(here: Bool, animated: Bool) {
        let time = model.clipTime(of: clip)
        let tolerance = model.keyframeTolerance
        if here {
            let commands = KeyframeEdits.removeKeyframes(in: clip, at: time, parameters: parameters, tolerance: tolerance)
            guard !commands.isEmpty else { return }
            model.apply(EditBatch(label: "Remove \(name.lowercased()) keyframe", commands: commands))
        } else {
            let commands = parameters.compactMap { KeyframeEdits.addKeyframe($0, in: clip, at: time, tolerance: tolerance) }
            guard !commands.isEmpty else { return }
            model.apply(EditBatch(label: animated ? "Add \(name.lowercased()) keyframe" : "Animate \(name.lowercased())", commands: commands))
        }
    }
}
