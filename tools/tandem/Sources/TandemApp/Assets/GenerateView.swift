import SwiftUI
import TandemAssets

/// Generate, over music and sound effects: ElevenLabs makes new ones from
/// a description. Shows a spinner while takes are on their way.
struct GenerateButton: View {
    let model: EditorModel
    let kind: AssetKind
    @State private var showing = false

    var body: some View {
        let host = AssetLibraryHost.shared
        Button { showing = true } label: {
            HStack(spacing: 4) {
                if host.generations[kind]?.running == true {
                    ProgressView().controlSize(.mini)
                }
                Text("Generate")
            }
        }
        .buttonStyle(.plain)
        .font(.ui(11.5))
        .foregroundStyle(Theme.amber.color)
        .tip(kind == .music ? "Make music from a description with ElevenLabs" : "Make a sound effect from a description with ElevenLabs")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            GenerateView(model: model, kind: kind)
        }
    }
}

/// The form: what to make, how long, how many takes, what it costs, and
/// the takes once they're back (hover to hear, double-click to add).
struct GenerateView: View {
    let model: EditorModel
    let kind: AssetKind

    private var host: AssetLibraryHost { .shared }

    var body: some View {
        let form = host.forms[kind] ?? GenerationForm(kind: kind)
        let blocker = GenerationForm.blocker(for: kind, status: host.elevenLabs?.status, refused: host.refused)
        let generation = host.generations[kind]
        let running = generation?.running == true
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(kind == .music ? "Generate music" : "Generate a sound effect")
                    .font(.ui(13, .bold))
                    .foregroundStyle(Theme.text.color)
                Text("ElevenLabs makes it from your description. Every take joins the library with its prompt.")
                    .font(.ui(11))
                    .foregroundStyle(Theme.textFaint.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ZStack(alignment: .topLeading) {
                TextEditor(text: binding(\.prompt))
                    .font(.ui(12))
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 6)
                if form.prompt.isEmpty {
                    Text(kind == .music ? "Calm lo-fi bed with soft keys, 80 BPM" : "Soft whoosh, like a card sliding across a table")
                        .font(.ui(12))
                        .foregroundStyle(Theme.textFaint.color)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: 66)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.field.color))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.fieldBorder.color, lineWidth: 1))
            HStack(spacing: 8) {
                Text("Length")
                    .font(.ui(12))
                    .foregroundStyle(Theme.textMuted.color)
                    .frame(width: 52, alignment: .leading)
                TextField("", value: binding(\.seconds), format: .number.precision(.fractionLength(0...1)))
                    .textFieldStyle(.plain)
                    .font(.ui(12).monospacedDigit())
                    .multilineTextAlignment(.trailing)
                    .frame(width: 44)
                    .padding(.horizontal, 6)
                    .frame(height: 22)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Theme.field.color))
                Text("s").font(.ui(12)).foregroundStyle(Theme.textFaint.color)
                Stepper("Length", value: binding(\.seconds), in: form.range, step: kind == .music ? 5 : 0.5)
                    .labelsHidden()
                Spacer(minLength: 8)
                Text(form.takes == 1 ? "1 take" : "\(form.takes) takes")
                    .font(.ui(12))
                    .foregroundStyle(Theme.textMuted.color)
                Stepper("Takes", value: binding(\.takes), in: 1...GenerationForm.maxTakes)
                    .labelsHidden()
            }
            if kind == .music {
                Toggle("Instrumental, no vocals", isOn: binding(\.instrumental))
                    .font(.ui(12))
            } else {
                Toggle("Loop seamlessly", isOn: binding(\.loop))
                    .font(.ui(12))
            }
            if let blocker {
                Text(blocker.message)
                    .font(.ui(11.5))
                    .foregroundStyle(blocker.canTry ? Theme.amber.color : Theme.red.color)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                Text(form.costNote)
                    .font(.ui(11))
                    .foregroundStyle(Theme.textFaint.color)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button {
                    host.generate(form)
                } label: {
                    Text(blocker?.canTry == true ? "Try again" : "Generate")
                        .font(.ui(12, .bold))
                        .foregroundStyle(Theme.onAmber.color)
                        .padding(.horizontal, 12)
                        .frame(height: 26)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.amber.color))
                }
                .buttonStyle(.plain)
                .disabled(form.problem != nil || running || blocker?.canTry == false)
                .opacity(form.problem != nil || running || blocker?.canTry == false ? 0.45 : 1)
                .tip(form.problem ?? "Send it to ElevenLabs")
            }
            if running {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(form.request.variations == 1 ? "Generating…" : "Generating \(form.request.variations) takes…")
                        .font(.ui(11.5))
                        .foregroundStyle(Theme.textMuted.color)
                }
            }
            if let generation, !running {
                if let error = generation.error {
                    Text("Couldn't generate: \(error)")
                        .font(.ui(11.5))
                        .foregroundStyle(Theme.red.color)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(generation.failures, id: \.self) { failure in
                    Text(failure)
                        .font(.ui(11))
                        .foregroundStyle(Theme.amber.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !generation.takes.isEmpty {
                    Text(generation.takes.count == 1 ? "Your take, in the library now" : "Your \(generation.takes.count) takes, in the library now")
                        .font(.ui(11.5, .semibold))
                        .foregroundStyle(Theme.textMuted.color)
                    VStack(spacing: 4) {
                        ForEach(generation.takes) { take in
                            AssetAudioRow(model: model, asset: take)
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 340)
        .onAppear { host.refreshProviders() }
    }

    private func binding<Value>(_ path: WritableKeyPath<GenerationForm, Value>) -> Binding<Value> {
        let kind = kind
        let host = host
        return Binding(
            get: { (host.forms[kind] ?? GenerationForm(kind: kind))[keyPath: path] },
            set: { value in
                var form = host.forms[kind] ?? GenerationForm(kind: kind)
                form[keyPath: path] = value
                host.forms[kind] = form
            }
        )
    }
}
