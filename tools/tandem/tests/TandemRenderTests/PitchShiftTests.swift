import AVFoundation
import XCTest
import TandemCore
import TandemMedia
@testable import TandemRender

final class PitchShiftTests: XCTestCase {
    /// Dominant frequency by counting zero crossings on the left channel.
    func frequency(_ samples: [Float], at seconds: Double, window: Double = 0.2) -> Double {
        let start = Int(seconds * 48_000), frames = Int(window * 48_000)
        var crossings = 0
        for i in stride(from: start * 2 + 2, to: (start + frames) * 2, by: 2) where (samples[i - 2] < 0) != (samples[i] < 0) {
            crossings += 1
        }
        return Double(crossings) / 2 / window
    }

    /// A 440 Hz tone with a silent hole from 1.0 to 1.2 s, to check sync.
    func toneWithHole(_ media: TestMedia) async throws -> MediaItem {
        try await media.movie("tone.mov", seconds: 3, draw: { TestMedia.fill($1, 0, 0, 0) }, sound: { i in
            let t = Double(i) / 48_000
            return (1.0..<1.2).contains(t) ? 0 : Float(0.25 * sin(2 * Double.pi * 440 * t))
        })
        return media.item("med_t", "tone.mov", seconds: 3, audio: true)
    }

    func export(_ media: TestMedia, clip: Clip, item: MediaItem) async throws -> [Float] {
        PitchShift.cacheFolder = media.folder.appendingPathComponent("pitch-cache", isDirectory: true)
        let project = smallProject(video: [], audio: [Track(kind: .audio, name: "A1", clips: [clip])], media: [item])
        let out = media.folder.appendingPathComponent("pitched.mp4")
        _ = try await Exporter(context: RenderContext(project: project, folder: media.projectFolder),
                               preset: ExportPreset(name: "t", codec: .h264, videoBitrate: 2_000_000, loudnessTarget: nil), output: out).run()
        return try await decodeAudio(out)
    }

    func testAnOctaveUpKeepsLengthAndSync() async throws {
        let media = try TestMedia()
        let item = try await toneWithHole(media)
        var clip = Clip(id: "clip_p", content: .media(mediaID: "med_t"), start: .zero, duration: t(2), sourceStart: t(0.5))
        clip.audio = AudioProperties(effects: [Effect(type: "pitchShift", params: ["semitones": .number(12)])])
        let samples = try await export(media, clip: clip, item: item)
        XCTAssertEqual(Double(samples.count / 2) / 48_000, 2, accuracy: 0.03)
        XCTAssertEqual(frequency(samples, at: 0.1), 880, accuracy: 20)
        XCTAssertEqual(frequency(samples, at: 1.5), 880, accuracy: 20)
        // The hole (source 1.0 to 1.2 s) is still at 0.5 to 0.7 s.
        let after = stride(from: Int(0.6 * 48_000), to: Int(1.0 * 48_000), by: 1).first { abs(samples[$0 * 2]) > 0.05 }
        XCTAssertEqual(Double(try XCTUnwrap(after)) / 48_000, 0.7, accuracy: 0.012)
        let before = (Int(0.2 * 48_000)..<Int(0.6 * 48_000)).last { abs(samples[$0 * 2]) > 0.05 }
        XCTAssertEqual(Double(try XCTUnwrap(before)) / 48_000, 0.5, accuracy: 0.012)
    }

    func testKeyframedPitchRamps() async throws {
        let media = try TestMedia()
        let item = try await toneWithHole(media)
        let shift = Effect(id: "fx_pitch", type: "pitchShift", params: ["semitones": .number(0)])
        var clip = Clip(id: "clip_p", content: .media(mediaID: "med_t"), start: .zero, duration: t(0.9), sourceStart: t(0))
        clip.audio = AudioProperties(effects: [shift])
        clip.keyframes["audio.effects.fx_pitch.semitones"] = [
            Keyframe(time: t(0), value: .number(0), interpolation: .hold),
            Keyframe(time: t(0.5), value: .number(7))
        ]
        let samples = try await export(media, clip: clip, item: item)
        XCTAssertEqual(frequency(samples, at: 0.1, window: 0.3), 440, accuracy: 15)
        XCTAssertEqual(frequency(samples, at: 0.6, window: 0.25), 440 * pow(2, 7.0 / 12), accuracy: 20)
    }

    func testNoShiftNoRender() {
        var clip = Clip(content: .media(mediaID: "med_t"), start: .zero, duration: t(1))
        clip.audio = AudioProperties(effects: [Effect(type: "pitchShift", params: ["semitones": .number(0)])])
        XCTAssertNil(PitchShift.effect(of: clip, registry: .standard))
        clip.audio?.effects[0].enabled = false
        clip.audio?.effects[0].params["semitones"] = .number(5)
        XCTAssertNil(PitchShift.effect(of: clip, registry: .standard))
        clip.audio?.effects[0].enabled = true
        XCTAssertNotNil(PitchShift.effect(of: clip, registry: .standard))
    }
}
