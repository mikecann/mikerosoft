import SwiftUI
import TandemCore

/// A diamond drawn as a shape, for keyframe buttons.
struct DiamondShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
        path.closeSubpath()
        return path
    }
}

/// The diamond beside an animatable control: grey outline when the
/// parameter isn't animated, amber outline when it is, filled amber when
/// there's a keyframe at the playhead. Click to add or remove that
/// keyframe.
struct KeyframeButton: View {
    let model: EditorModel
    let clip: Clip
    let parameter: String

    var body: some View {
        let animated = KeyframeEdits.isAnimated(parameter, in: clip)
        // Only animated parameters follow the playhead, so a still clip's
        // inspector doesn't redraw during playback.
        let here = animated && !KeyframeEdits.parameters(in: clip, keyedAt: model.clipTime(of: clip), tolerance: model.keyframeTolerance, among: [parameter]).isEmpty
        Button {
            model.toggleKeyframe(parameter, in: clip)
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
        .help(help(animated: animated, here: here))
    }

    private func help(animated: Bool, here: Bool) -> String {
        let name = KeyframeEdits.name(of: parameter, in: clip).lowercased()
        if here { return "Remove the \(name) keyframe at the playhead" }
        if animated { return "Add a \(name) keyframe at the playhead" }
        return "Animate \(name): add a keyframe at the playhead"
    }
}

/// A clip's animation at a glance: what animates, how many keyframes,
/// stepping between them, and the easing of the one at the playhead.
struct AnimationSection: View {
    let model: EditorModel
    let clip: Clip
    /// "video." or "audio."
    let domain: String

    var body: some View {
        let parameters = clip.keyframes.keys.filter { $0.hasPrefix(domain) }.sorted(by: KeyframeEdits.order)
        if !parameters.isEmpty {
            let tolerance = model.keyframeTolerance
            let clipTime = model.clipTime(of: clip)
            let here = KeyframeEdits.parameters(in: clip, keyedAt: clipTime, tolerance: tolerance, among: parameters)
            let count = KeyframeEdits.times(in: clip, parameters: parameters, tolerance: tolerance).count
            InspectorSection(title: "Animation", accessory: {
                HStack(spacing: 2) {
                    StepButton(symbol: "chevron.left", help: "Previous keyframe (Shift-J)") { model.seekKeyframe(forward: false) }
                    Button { model.toggleKeyframes() } label: {
                        ZStack {
                            DiamondShape().fill(here.isEmpty ? Color.clear : Theme.amber.color)
                            DiamondShape().stroke(Theme.amber.color, lineWidth: 1.2)
                        }
                        .frame(width: 10, height: 10)
                        .frame(width: 22, height: 20)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(here.isEmpty ? "Add a keyframe at the playhead (Option-K)" : "Remove the keyframe at the playhead (Option-K)")
                    StepButton(symbol: "chevron.right", help: "Next keyframe (Shift-K)") { model.seekKeyframe(forward: true) }
                }
            }) {
                InfoRow(label: "Animates", value: KeyframeEdits.summary(of: parameters, in: clip))
                InfoRow(label: "Keyframes", value: count == 1 ? "1" : "\(count)")
                if here.isEmpty {
                    Text("Put the playhead on a keyframe to change its easing.")
                        .font(.ui(11))
                        .foregroundStyle(Theme.textFaint.color)
                } else {
                    HStack(spacing: 10) {
                        Text("Easing")
                            .font(.ui(12))
                            .foregroundStyle(Theme.textMuted.color)
                            .frame(width: 86, alignment: .leading)
                        let current = KeyframeEdits.easing(in: clip, at: clipTime, tolerance: tolerance) ?? .easeInOut
                        Menu {
                            ForEach(Interpolation.menuOrder, id: \.self) { easing in
                                Button {
                                    model.setEasing(easing, in: clip, at: clipTime, parameters: here)
                                } label: {
                                    if easing == current { Label(easing.displayName, systemImage: "checkmark") } else { Text(easing.displayName) }
                                }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text(current.displayName)
                                    .font(.ui(12))
                                    .foregroundStyle(Theme.text.color)
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.system(size: 8, weight: .semibold))
                                    .foregroundStyle(Theme.textFaint.color)
                            }
                        }
                        .menuStyle(.button)
                        .buttonStyle(.plain)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("How the values move on from the keyframe at the playhead")
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }
}

private struct StepButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Theme.textMuted.color)
                .frame(width: 18, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
