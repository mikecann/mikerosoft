import SwiftUI
import TandemCore

/// "Tighten pauses…": previews how many pauses the transcript shows and
/// cuts them in one undoable batch.
struct TightenPausesPopover: View {
    let model: EditorModel
    let dismiss: () -> Void
    @State private var minimum = 0.6
    @State private var keep = 0.15
    @State private var onlyInOut = false

    var body: some View {
        let ranges = PauseTightening.ranges(
            in: model.project,
            transcript: { model.session.analysis.transcript(for: $0) },
            minimum: Time(seconds: minimum),
            keep: Time(seconds: keep),
            within: onlyInOut ? model.inOutRange : nil
        )
        let total = ranges.reduce(0) { $0 + $1.duration.seconds }
        VStack(alignment: .leading, spacing: 12) {
            Text("Tighten pauses")
                .font(.ui(13, .bold))
                .foregroundStyle(Theme.text.color)
            Text("Cuts silences between words out of the take. Camera, screen and voice stay in sync; B-roll and music follow.")
                .font(.ui(11.5))
                .foregroundStyle(Theme.textMuted.color)
                .fixedSize(horizontal: false, vertical: true)
            SliderRow(label: "Longer than", value: minimum, range: 0.3...2, format: { String(format: "%.1f s", $0) }) { minimum = $0 }
            SliderRow(label: "Leave", value: keep, range: 0...0.5, format: { String(format: "%.2f s", $0) }) { keep = $0 }
            if model.inOutRange != nil {
                HStack {
                    Text("Only between in and out").font(.ui(12)).foregroundStyle(Theme.textMuted.color)
                    Spacer()
                    GraphiteSwitch(isOn: onlyInOut) { onlyInOut.toggle() }
                }
            }
            Rectangle().fill(Theme.border.color).frame(height: 1)
            HStack {
                if ranges.isEmpty {
                    Text(hasTranscript ? "No pauses that long." : "Needs a transcript of the take first.")
                        .font(.ui(12))
                        .foregroundStyle(Theme.textFaint.color)
                } else {
                    Text(String(format: "%d %@, %.1f s in all", ranges.count, ranges.count == 1 ? "pause" : "pauses", total))
                        .font(.ui(12, .semibold))
                        .foregroundStyle(Theme.text.color)
                }
                Spacer()
                Button {
                    model.apply(PauseTightening.batch(ranges))
                    dismiss()
                } label: {
                    Text("Tighten")
                        .font(.ui(12, .bold))
                        .foregroundStyle(Theme.onAmber.color)
                        .padding(.horizontal, 14)
                        .frame(height: 26)
                        .background(RoundedRectangle(cornerRadius: 7).fill(ranges.isEmpty ? Theme.segmentSelected.color : Theme.amber.color))
                }
                .buttonStyle(.plain)
                .disabled(ranges.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 330)
        .background(Theme.raised.color)
    }

    private var hasTranscript: Bool {
        model.project.media.contains { model.session.analysis.transcript(for: $0) != nil }
    }
}
