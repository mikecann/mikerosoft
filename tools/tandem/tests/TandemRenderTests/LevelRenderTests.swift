import AVFoundation
import XCTest
import TandemCore
import TandemMedia
@testable import TandemRender

/// Normalise and clip gain as they're heard: in an export, and the same in
/// the viewer's composition as in the export's.
final class LevelRenderTests: XCTestCase {
    /// A camera take with a steady 1 kHz tone at -30 dBFS, and what the
    /// loudness analysis would measure for it.
    func take(_ media: TestMedia, seconds: Double = 3) async throws -> (MediaItem, FakeAssets) {
        let url = try await media.movie("take.mov", seconds: seconds, draw: { TestMedia.fill($1, 0, 0, 0) }, sound: { i in
            Float(pow(10, -30.0 / 20) * sin(2 * Double.pi * 1000 * Double(i) / 48_000))
        })
        let item = media.item("med_take", "take.mov", role: .camera, seconds: seconds, audio: true)
        var meter = LoudnessMeter(sampleRate: 48_000, channels: 2)
        meter.process(interleaved: try await decodeAudio(url))
        let assets = FakeAssets()
        assets.loudnesses[item.id] = Loudness(integratedLUFS: meter.integrated, truePeakDBTP: meter.truePeak, loudnessRange: 0)
        return (item, assets)
    }

    func testANormalisedClipPlaysAtItsLevelPlusItsGain() async throws {
        let media = try TestMedia()
        let (item, assets) = try await take(media)
        let measured = try XCTUnwrap(assets.loudnesses[item.id]?.integratedLUFS)
        XCTAssertEqual(measured, -30, accuracy: 1.5, "a -30 dBFS tone at 1 kHz")
        for (gain, expected) in [(0.0, -20.0), (2.0, -18.0), (-3.0, -23.0)] {
            var clip = Clip(id: "clip_v", content: .media(mediaID: item.id), start: .zero, duration: t(3))
            clip.audio = AudioProperties(gainDB: gain, normalizeTo: -20)
            let project = smallProject(video: [], audio: [Track(kind: .audio, name: "Voice", clips: [clip])], media: [item])
            let out = media.folder.appendingPathComponent("level \(gain).mp4")
            // No master loudness, so the file plays the mix as it is.
            let preset = ExportPreset(name: "Test", codec: .h264, videoBitrate: 2_000_000, loudnessTarget: nil, truePeakCeiling: nil)
            let result = try await Exporter(context: RenderContext(project: project, folder: media.projectFolder, assets: assets), preset: preset, output: out).run()
            XCTAssertEqual(try XCTUnwrap(result.integratedLUFS), expected, accuracy: 0.3, "normalised to -20, then \(gain) dB")
        }
    }

    func testTheExportMasterStillLandsOnTheTarget() async throws {
        let media = try TestMedia()
        let (item, assets) = try await take(media)
        var clip = Clip(id: "clip_v", content: .media(mediaID: item.id), start: .zero, duration: t(3))
        clip.audio = AudioProperties(normalizeTo: -20)
        let project = smallProject(video: [], audio: [Track(kind: .audio, name: "Voice", clips: [clip])], media: [item])
        let out = media.folder.appendingPathComponent("mastered.mp4")
        let preset = ExportPreset(name: "Test", codec: .h264, videoBitrate: 2_000_000)
        let result = try await Exporter(context: RenderContext(project: project, folder: media.projectFolder, assets: assets), preset: preset, output: out).run()
        XCTAssertEqual(try XCTUnwrap(result.integratedLUFS), -14, accuracy: 0.5)
        XCTAssertLessThanOrEqual(try XCTUnwrap(result.truePeakDBTP), -1 + 0.05)
    }

    /// The viewer builds from proxies at a preview size; export from the
    /// originals at full size. Their sound must level the same.
    func testTheViewerAndTheExportLevelTheSame() async throws {
        let media = try TestMedia()
        let (item, assets) = try await take(media, seconds: 4)
        var normalised = Clip(id: "clip_a", content: .media(mediaID: item.id), start: .zero, duration: t(2))
        normalised.audio = AudioProperties(gainDB: 1.5, fadeOut: t(0.5), normalizeTo: -20)
        var plain = Clip(id: "clip_b", content: .media(mediaID: item.id), start: t(2), duration: t(2), sourceStart: t(2))
        plain.audio = AudioProperties(gainDB: -6)
        let project = smallProject(video: [], audio: [Track(kind: .audio, name: "Voice", clips: [normalised, plain])], media: [item])
        let viewer = RenderContext(project: project, folder: media.projectFolder, useProxies: true, assets: assets, sizeOverride: CGSize(width: 160, height: 90))
        let export = RenderContext(project: project, folder: media.projectFolder, useProxies: false, assets: assets)
        let played = try await CompositionBuilder.build(viewer)
        let exported = try await CompositionBuilder.build(export)
        let times = stride(from: 0.0, through: 3.99, by: 0.05).map { t($0) }
        let heard = volumes(played.audioMix, at: times)
        XCTAssertEqual(heard, volumes(exported.audioMix, at: times))
        // +10 dB to reach -20 from about -30, then +1.5 dB; the plain clip -6 dB.
        let measured = try XCTUnwrap(assets.loudnesses[item.id]?.integratedLUFS)
        let expected = Float(pow(10, (-20 - measured + 1.5) / 20))
        XCTAssertEqual(try XCTUnwrap(heard[t(1)]), expected, accuracy: expected * 0.001)
        XCTAssertEqual(try XCTUnwrap(heard[t(3)]), Float(pow(10, -6.0 / 20)), accuracy: 0.001)
    }

    /// The loudest volume any input of the mix has at each time.
    func volumes(_ mix: AVAudioMix, at times: [Time]) -> [Time: Float] {
        var result: [Time: Float] = [:]
        for time in times {
            var loudest: Float = 0
            for parameters in mix.inputParameters {
                var start: Float = 0, end: Float = 0
                var range = CMTimeRange()
                guard parameters.getVolumeRamp(for: time.cmTime, startVolume: &start, endVolume: &end, timeRange: &range) else { continue }
                let span = range.duration.seconds
                let p = span > 0 ? Float((time.cmTime - range.start).seconds / span) : 0
                loudest = max(loudest, start + (end - start) * p)
            }
            result[time] = loudest
        }
        return result
    }
}
