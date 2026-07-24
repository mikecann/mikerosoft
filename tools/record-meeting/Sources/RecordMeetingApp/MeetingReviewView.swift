import AVFoundation
import SwiftUI

struct AudioWaveformView: View {
    let samples: [Double]
    var progress: Double? = nil

    var body: some View {
        GeometryReader { geometry in
            let count = max(1, Int(geometry.size.width / 3))
            let bars = WaveformMath.resample(samples, targetCount: count)
            let boundedProgress = min(1, max(0, progress ?? 0))

            Canvas { context, size in
                guard !bars.isEmpty else {
                    var baseline = Path()
                    baseline.move(to: CGPoint(x: 0, y: size.height / 2))
                    baseline.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                    context.stroke(baseline, with: .color(.secondary.opacity(0.3)), lineWidth: 1)
                    return
                }

                let spacing = size.width / CGFloat(bars.count)
                let barWidth = max(1, spacing * 0.58)
                for (index, level) in bars.enumerated() {
                    let height = max(2, CGFloat(level) * (size.height - 6))
                    let x = CGFloat(index) * spacing + (spacing - barWidth) / 2
                    let rect = CGRect(
                        x: x,
                        y: (size.height - height) / 2,
                        width: barWidth,
                        height: height
                    )
                    let ratio = Double(index + 1) / Double(bars.count)
                    let color: Color = progress == nil || ratio > boundedProgress
                        ? .secondary.opacity(0.55)
                        : .accentColor
                    context.fill(
                        Path(roundedRect: rect, cornerRadius: barWidth / 2),
                        with: .color(color)
                    )
                }

                if progress != nil {
                    let x = CGFloat(boundedProgress) * size.width
                    var playhead = Path()
                    playhead.move(to: CGPoint(x: x, y: 0))
                    playhead.addLine(to: CGPoint(x: x, y: size.height))
                    context.stroke(playhead, with: .color(.primary), lineWidth: 2)
                }
            }
        }
        .accessibilityLabel("Audio waveform")
    }
}

struct MeetingReviewView: View {
    @ObservedObject var model: MeetingViewModel
    let meeting: ProcessedMeeting

    @StateObject private var playback = MeetingPlaybackController()
    @State private var names: [String: String] = [:]
    @State private var samplePlayer: AVAudioPlayer?

    private var activeSegmentIndex: Int? {
        TranscriptTimeline.activeSegmentIndex(
            at: playback.currentTime,
            segments: meeting.document.segments
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            playbackTimeline
            Divider()

            HStack(alignment: .top, spacing: 18) {
                speakerPanel
                    .frame(width: 250)
                Divider()
                transcriptPanel
            }

            Divider()
            HStack {
                Text("Click a transcript line to jump to it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Save transcript") {
                    playback.stop()
                    samplePlayer?.stop()
                    Task { await model.finalizeSpeakerNames(names) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isProcessing)
            }
        }
        .padding(22)
        .frame(width: 900, height: 700)
        .onAppear {
            for (index, speaker) in meeting.document.speakers.enumerated() {
                names[speaker.id] = "Speaker \(index + 1)"
            }
            do {
                try playback.load(url: meeting.audioURL)
            } catch {
                model.presentedError = "Could not load the meeting audio: \(error.localizedDescription)"
            }
        }
        .onDisappear {
            playback.stop()
            samplePlayer?.stop()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(meeting.title)
                .font(.title2.bold())
            Text("Review the recording, scrub the timeline, and name the detected speakers.")
                .foregroundStyle(.secondary)
        }
    }

    private var playbackTimeline: some View {
        VStack(spacing: 10) {
            GeometryReader { geometry in
                AudioWaveformView(
                    samples: meeting.waveformSamples,
                    progress: playback.duration > 0 ? playback.currentTime / playback.duration : 0
                )
                .padding(.horizontal, 6)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard playback.duration > 0 else { return }
                            let ratio = value.location.x / max(1, geometry.size.width)
                            playback.seek(
                                to: min(1, max(0, ratio)) * playback.duration
                            )
                        }
                )
            }
            .frame(height: 72)

            Slider(
                value: Binding(
                    get: { playback.currentTime },
                    set: { playback.seek(to: $0) }
                ),
                in: 0...max(0.01, playback.duration)
            )

            HStack {
                Text(TranscriptDocument.timestamp(playback.currentTime))
                    .monospacedDigit()
                Spacer()
                Button {
                    playback.skip(by: -10)
                } label: {
                    Label("Back 10 seconds", systemImage: "gobackward.10")
                        .labelStyle(.iconOnly)
                }
                Button {
                    playback.togglePlayback()
                } label: {
                    Label(
                        playback.isPlaying ? "Pause" : "Play",
                        systemImage: playback.isPlaying ? "pause.circle.fill" : "play.circle.fill"
                    )
                    .font(.title2)
                    .labelStyle(.iconOnly)
                }
                .keyboardShortcut(.space, modifiers: [])
                Button {
                    playback.skip(by: 10)
                } label: {
                    Label("Forward 10 seconds", systemImage: "goforward.10")
                        .labelStyle(.iconOnly)
                }
                Spacer()
                Text(TranscriptDocument.timestamp(playback.duration))
                    .monospacedDigit()
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    private var speakerPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Speakers")
                .font(.headline)
            Text("Play a sample, then enter the person’s name.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(Array(meeting.document.speakers.enumerated()), id: \.element.id) { index, speaker in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Button {
                                    playSample(path: speaker.samplePath)
                                } label: {
                                    Image(systemName: "play.circle.fill")
                                }
                                .buttonStyle(.plain)
                                .help("Play voice sample")
                                .disabled(speaker.samplePath.isEmpty)
                                Text("Speaker \(index + 1)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            TextField(
                                "Name",
                                text: binding(for: speaker.id, fallback: "Speaker \(index + 1)")
                            )
                            .textFieldStyle(.roundedBorder)
                        }
                        .padding(9)
                        .background(
                            Color.secondary.opacity(0.07),
                            in: RoundedRectangle(cornerRadius: 9)
                        )
                    }
                }
            }
        }
    }

    private var transcriptPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Transcript")
                    .font(.headline)
                Spacer()
                Text("\(meeting.document.segments.count) lines")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(meeting.document.segments.enumerated()), id: \.offset) { index, segment in
                            Button {
                                playback.seek(to: segment.start)
                            } label: {
                                transcriptRow(segment: segment, isActive: index == activeSegmentIndex)
                            }
                            .buttonStyle(.plain)
                            .id(index)
                        }
                    }
                    .padding(.trailing, 6)
                }
                .onChange(of: activeSegmentIndex) { _, newIndex in
                    guard let newIndex else { return }
                    withAnimation(.easeOut(duration: 0.18)) {
                        proxy.scrollTo(newIndex, anchor: .center)
                    }
                }
            }
        }
    }

    private func transcriptRow(segment: TranscriptSegment, isActive: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(TranscriptDocument.timestamp(segment.start))
                .font(.caption.monospacedDigit())
                .foregroundStyle(isActive ? Color.accentColor : .secondary)
                .frame(width: 46, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                Text(TranscriptDocument.displayName(for: segment.speaker, names: names))
                    .font(.caption.bold())
                    .foregroundStyle(isActive ? Color.accentColor : .secondary)
                Text(segment.text.trimmingCharacters(in: .whitespacesAndNewlines))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(
            isActive ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.06),
            in: RoundedRectangle(cornerRadius: 9)
        )
        .overlay {
            if isActive {
                RoundedRectangle(cornerRadius: 9)
                    .stroke(Color.accentColor.opacity(0.65), lineWidth: 1)
            }
        }
    }

    private func binding(for id: String, fallback: String) -> Binding<String> {
        Binding(
            get: { names[id] ?? fallback },
            set: { names[id] = $0 }
        )
    }

    private func playSample(path: String) {
        playback.pause()
        do {
            samplePlayer = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: path))
            samplePlayer?.play()
        } catch {
            model.presentedError = "Could not play the speaker sample: \(error.localizedDescription)"
        }
    }
}
