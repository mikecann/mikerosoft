import AVFoundation
import XCTest
import TandemCore
import TandemMedia
@testable import TandemAssets

final class NormaliserTests: XCTestCase {
    let normaliser = AssetNormaliser(registersFonts: true)

    func testSineWAVIsResampledTo48kWithLoudnessAndPeaks() async throws {
        let folder = tempFolder("audio")
        let input = folder.appendingPathComponent("original.wav")
        try Generated.sineWAV(at: input, seconds: 1, sampleRate: 44_100, channels: 2, dbfs: -20)

        let result = try await normaliser.normalise(input, into: folder)

        XCTAssertEqual(result.format, .wav)
        XCTAssertEqual(result.file, "normalised.wav")
        XCTAssertEqual(result.mediaKind, .audio)
        XCTAssertTrue(result.hasAudio)
        XCTAssertEqual(try XCTUnwrap(result.duration), 1, accuracy: 0.002)
        let file = try AVAudioFile(forReading: folder.appendingPathComponent("normalised.wav"))
        XCTAssertEqual(file.fileFormat.sampleRate, 48_000)
        XCTAssertEqual(file.fileFormat.channelCount, 2)
        XCTAssertEqual(file.fileFormat.settings[AVLinearPCMBitDepthKey] as? Int, 24)
        XCTAssertEqual(Double(file.length), 48_000, accuracy: 100)

        // A stereo sine at -20 dBFS reads -20 LUFS (EBU Tech 3341 scaled).
        let loudness = try XCTUnwrap(result.loudness)
        XCTAssertEqual(loudness.integratedLUFS, -20, accuracy: 0.2)
        XCTAssertEqual(loudness.truePeakDBTP, -20, accuracy: 0.5)
        let stored = try JSONDecoder().decode(Loudness.self, from: Data(contentsOf: folder.appendingPathComponent("loudness.json")))
        XCTAssertEqual(stored, loudness)

        XCTAssertEqual(result.peaks, "peaks.bin")
        let waveform = try AudioNormaliser.readPeaks(from: folder.appendingPathComponent("peaks.bin"))
        XCTAssertEqual(waveform.peaks.count, 100, accuracy: 1)
        XCTAssertEqual(Double(waveform.peaks.max() ?? 0), 0.1, accuracy: 0.01)

        XCTAssertEqual(result.thumbnail, "thumbnail.jpg")
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("thumbnail.jpg").path))
    }

    func testMonoStaysMonoAndSilenceHasFiniteLoudness() async throws {
        let folder = tempFolder("mono")
        let input = folder.appendingPathComponent("original.wav")
        try WAVFile.wrap(pcm16: Data(count: 44_100 * 2), sampleRate: 44_100, channels: 1).write(to: input)
        let result = try await normaliser.normalise(input, into: folder)
        let file = try AVAudioFile(forReading: folder.appendingPathComponent("normalised.wav"))
        XCTAssertEqual(file.fileFormat.channelCount, 1)
        XCTAssertEqual(result.loudness?.integratedLUFS, -144)
        XCTAssertEqual(try XCTUnwrap(result.duration), 1, accuracy: 0.001)
    }

    func testAnimatedGIFBecomesHEVCWithAlpha() async throws {
        let folder = tempFolder("gif")
        let input = folder.appendingPathComponent("original.gif")
        try Generated.animatedGIF(at: input, size: 64, frames: 10, delay: 0.05)

        let result = try await normaliser.normalise(input, into: folder)

        XCTAssertEqual(result.format, .gif)
        XCTAssertEqual(result.file, "normalised.mov")
        XCTAssertEqual(result.mediaKind, .video)
        XCTAssertTrue(result.hasAlpha)
        XCTAssertFalse(result.hasAudio)
        XCTAssertEqual(result.width, 64)
        XCTAssertEqual(result.height, 64)
        XCTAssertEqual(try XCTUnwrap(result.duration), 0.5, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(result.frameRate), 20, accuracy: 0.5)

        let movie = folder.appendingPathComponent("normalised.mov")
        let frames = try await Generated.frameCount(of: movie)
        XCTAssertEqual(frames, 10)
        // Top left stays clear; the square (x 0...32 in frame 0, rows 16...48) is solid.
        let clear = try await Generated.alpha(of: movie, x: 2, y: 2)
        let solid = try await Generated.alpha(of: movie, x: 16, y: 32)
        XCTAssertLessThan(clear, 10)
        XCTAssertGreaterThan(solid, 240)
        XCTAssertEqual(result.thumbnail, "thumbnail.png")
    }

    func testSVGBecomesPNGAtTheRequestedSize() async throws {
        let folder = tempFolder("svg")
        let input = folder.appendingPathComponent("original.svg")
        try Generated.svg(at: input)
        let normaliser = AssetNormaliser(svgLongSide: 480)

        let result = try await normaliser.normalise(input, into: folder)

        XCTAssertEqual(result.format, .svg)
        XCTAssertEqual(result.file, "normalised.png")
        XCTAssertEqual(result.width, 480)
        XCTAssertEqual(result.height, 240)
        XCTAssertTrue(result.hasAlpha)
        let info = try XCTUnwrap(MediaProbe.image(folder.appendingPathComponent("normalised.png")))
        XCTAssertEqual(info.width, 480)
        XCTAssertEqual(info.height, 240)
        XCTAssertTrue(info.hasAlpha)
        XCTAssertEqual(result.thumbnail, "thumbnail.png")
    }

    func testStillImagesAreUsedAsTheyAre() async throws {
        let folder = tempFolder("png")
        let input = folder.appendingPathComponent("original.png")
        let context = CGContext(data: nil, width: 40, height: 30, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
        try ImageFiles.write(context.makeImage()!, to: input, type: .png)

        let result = try await normaliser.normalise(input, into: folder)

        XCTAssertNil(result.file)
        XCTAssertEqual(result.mediaKind, .image)
        XCTAssertEqual(result.width, 40)
        XCTAssertEqual(result.height, 30)
        XCTAssertFalse(result.hasAlpha)
        XCTAssertEqual(result.thumbnail, "thumbnail.jpg")
    }

    func testFontsAreRegisteredAndDescribed() async throws {
        guard let font = Generated.systemFont() else { throw XCTSkip("no system TTF found") }
        let folder = tempFolder("font")
        let input = folder.appendingPathComponent("original.ttf")
        try FileManager.default.copyItem(at: font, to: input)

        let result = try await normaliser.normalise(input, into: folder)

        XCTAssertEqual(result.format, .ttf)
        XCTAssertNil(result.file)
        XCTAssertNil(result.mediaKind)
        XCTAssertFalse(result.fonts.isEmpty)
        XCTAssertFalse(result.fonts[0].family.isEmpty)
        XCTAssertEqual(result.thumbnail, "thumbnail.jpg")
    }

    func testWebMWithAlphaGoesThroughFFmpeg() async throws {
        guard let ffmpeg = FFmpeg.locate() else { throw XCTSkip("ffmpeg isn't installed") }
        let folder = tempFolder("webm")
        let input = folder.appendingPathComponent("original.webm")
        // Half the frame is a solid square, the rest transparent.
        try ffmpeg.run([
            "-y", "-v", "error", "-f", "lavfi", "-i", "color=c=black@0.0:s=64x64:d=0.5:r=30,format=yuva420p",
            "-f", "lavfi", "-i", "color=c=red:s=32x32:d=0.5:r=30,format=yuva420p",
            "-filter_complex", "[0][1]overlay=0:0,format=yuva420p",
            "-c:v", "libvpx-vp9", "-pix_fmt", "yuva420p", "-auto-alt-ref", "0", input.path
        ])

        let result = try await AssetNormaliser(ffmpeg: ffmpeg).normalise(input, into: folder)

        XCTAssertEqual(result.format, .webm)
        XCTAssertEqual(result.file, "normalised.mov")
        XCTAssertTrue(result.hasAlpha)
        XCTAssertEqual(result.width, 64)
        XCTAssertEqual(try XCTUnwrap(result.duration), 0.5, accuracy: 0.05)
        let movie = folder.appendingPathComponent("normalised.mov")
        let solid = try await Generated.alpha(of: movie, x: 8, y: 8)
        let clear = try await Generated.alpha(of: movie, x: 56, y: 56)
        XCTAssertGreaterThan(solid, 240)
        XCTAssertLessThan(clear, 10)
    }

    func testOggAudioFallsBackToFFmpeg() async throws {
        guard let ffmpeg = FFmpeg.locate() else { throw XCTSkip("ffmpeg isn't installed") }
        let folder = tempFolder("ogg")
        let input = folder.appendingPathComponent("original.ogg")
        try ffmpeg.run(["-y", "-v", "error", "-f", "lavfi", "-i", "sine=frequency=440:duration=1:sample_rate=44100", "-c:a", "libvorbis", input.path])

        let result = try await AssetNormaliser(ffmpeg: ffmpeg).normalise(input, into: folder)

        XCTAssertEqual(result.format, .ogg)
        XCTAssertEqual(result.file, "normalised.wav")
        XCTAssertEqual(try XCTUnwrap(result.duration), 1, accuracy: 0.05)
        let file = try AVAudioFile(forReading: folder.appendingPathComponent("normalised.wav"))
        XCTAssertEqual(file.fileFormat.sampleRate, 48_000)
    }

    func testVideoIsProbedAndUsedAsItIs() async throws {
        guard let ffmpeg = FFmpeg.locate() else { throw XCTSkip("ffmpeg isn't installed") }
        let folder = tempFolder("mp4")
        let input = folder.appendingPathComponent("original.mp4")
        try ffmpeg.run(["-y", "-v", "error", "-f", "lavfi", "-i", "testsrc=size=160x90:rate=30:duration=1", "-pix_fmt", "yuv420p", "-c:v", "libx264", input.path])

        let result = try await normaliser.normalise(input, into: folder)

        XCTAssertEqual(result.format, .mp4)
        XCTAssertNil(result.file)
        XCTAssertEqual(result.mediaKind, .video)
        XCTAssertEqual(result.width, 160)
        XCTAssertEqual(result.height, 90)
        XCTAssertEqual(try XCTUnwrap(result.frameRate), 30, accuracy: 0.1)
        XCTAssertFalse(result.hasAlpha)
        XCTAssertEqual(result.thumbnail, "thumbnail.jpg")
    }

    func testUnknownFilesAreRefused() async throws {
        let folder = tempFolder("unknown")
        let input = folder.appendingPathComponent("original.xyz")
        try Data("hello".utf8).write(to: input)
        do {
            _ = try await normaliser.normalise(input, into: folder)
            XCTFail("expected an error")
        } catch let error as AssetError {
            guard case .unsupported = error else { return XCTFail("wrong error \(error)") }
        }
    }

    func testFormatSniffing() throws {
        func sniff(_ bytes: [UInt8], _ ext: String = "") -> AssetFormat {
            FormatSniffer.format(head: Data(bytes), fileExtension: ext)
        }
        XCTAssertEqual(sniff(Array("RIFF\0\0\0\0WAVE".utf8)), .wav)
        XCTAssertEqual(sniff(Array("RIFF\0\0\0\0WEBP".utf8)), .webp)
        XCTAssertEqual(sniff(Array("GIF89a".utf8)), .gif)
        XCTAssertEqual(sniff([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A]), .png)
        XCTAssertEqual(sniff([0xFF, 0xD8, 0xFF, 0xE0]), .jpeg)
        XCTAssertEqual(sniff([0x1A, 0x45, 0xDF, 0xA3]), .webm)
        XCTAssertEqual(sniff(Array("ID3\u{3}".utf8)), .mp3)
        XCTAssertEqual(sniff(Array("\0\0\0\u{18}ftypqt  ".utf8)), .mov)
        XCTAssertEqual(sniff(Array("\0\0\0\u{18}ftypisom".utf8)), .mp4)
        XCTAssertEqual(sniff(Array("\0\0\0\u{18}ftypM4A ".utf8)), .m4a)
        XCTAssertEqual(sniff(Array("wOF2".utf8)), .woff2)
        XCTAssertEqual(sniff(Array("OTTO".utf8)), .otf)
        XCTAssertEqual(sniff([0x00, 0x01, 0x00, 0x00]), .ttf)
        XCTAssertEqual(sniff(Array("<?xml version=\"1.0\"?>\n<svg xmlns=\"\">".utf8)), .svg)
        XCTAssertEqual(sniff(Array("OggS".utf8)), .ogg)
        XCTAssertEqual(sniff(Array("TITLE \"x\"\nLUT_3D_SIZE 33".utf8), "cube"), .cube)

        let folder = tempFolder("sniff")
        let lottie = folder.appendingPathComponent("anim.json")
        try Data(#"{"v":"5.8.1","fr":60,"ip":0,"op":10,"w":100,"h":100,"layers":[]}"#.utf8).write(to: lottie)
        XCTAssertEqual(FormatSniffer.format(of: lottie), .lottie)
        let other = folder.appendingPathComponent("other.json")
        try Data(#"{"hello": "world"}"#.utf8).write(to: other)
        XCTAssertEqual(FormatSniffer.format(of: other), .unknown)
    }

    func testWAVWrapAndChannelGuess() {
        let pcm = Data(count: 48_000 * 2 * 2)
        let wav = WAVFile.wrap(pcm16: pcm, sampleRate: 48_000, channels: 2)
        XCTAssertEqual(wav.count, 44 + pcm.count)
        XCTAssertEqual(String(decoding: wav.prefix(4), as: UTF8.self), "RIFF")
        XCTAssertEqual(WAVFile.guessChannels(byteCount: pcm.count, sampleRate: 48_000, expectedSeconds: 1), 2)
        XCTAssertEqual(WAVFile.guessChannels(byteCount: pcm.count / 2, sampleRate: 48_000, expectedSeconds: 1), 1)
        XCTAssertEqual(WAVFile.guessChannels(byteCount: pcm.count, sampleRate: 48_000, expectedSeconds: nil), 1)
        // A mono take half as long again as asked for is still mono.
        XCTAssertEqual(WAVFile.guessChannels(byteCount: pcm.count * 3 / 4, sampleRate: 48_000, expectedSeconds: 1), 1)
    }
}

final class LottieNormaliserTests: XCTestCase {
    func testLottieRendersToHEVCWithAlphaTheRightWayUp() async throws {
        guard AssetNormaliser.canRenderLottie else { throw XCTSkip("built without lottie-ios") }
        let folder = tempFolder("lottie")
        let input = folder.appendingPathComponent("original.json")
        try Generated.lottie(at: input)

        let result = try await AssetNormaliser(lottieLongSide: 100).normalise(input, into: folder)

        XCTAssertEqual(result.format, .lottie)
        XCTAssertEqual(result.file, "normalised.mov")
        XCTAssertTrue(result.hasAlpha)
        XCTAssertEqual(result.width, 100)
        XCTAssertEqual(result.height, 100)
        XCTAssertEqual(try XCTUnwrap(result.duration), 0.5, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(result.frameRate), 30, accuracy: 0.01)
        let movie = folder.appendingPathComponent("normalised.mov")
        let frames = try await Generated.frameCount(of: movie)
        XCTAssertEqual(frames, 15)
        // The square fills the top-left quarter.
        let topLeft = try await Generated.alpha(of: movie, x: 20, y: 20)
        let bottomLeft = try await Generated.alpha(of: movie, x: 20, y: 80)
        let topRight = try await Generated.alpha(of: movie, x: 80, y: 20)
        XCTAssertGreaterThan(topLeft, 240)
        XCTAssertLessThan(bottomLeft, 10)
        XCTAssertLessThan(topRight, 10)
    }

    func testLottieFallsBackToTheWebPWhenItCantRender() async throws {
        let folder = tempFolder("lottie-fallback")
        let broken = folder.appendingPathComponent("original.json")
        try Data(#"{"v":"5.7.4","fr":30,"ip":0,"op":15,"w":100,"h":100,"layers":"nope"}"#.utf8).write(to: broken)
        let gif = folder.appendingPathComponent("fallback.gif")
        try Generated.animatedGIF(at: gif, frames: 4)
        let result = try await AssetNormaliser().normalise(broken, into: folder, fallbacks: [gif])
        XCTAssertEqual(result.format, .gif)
        XCTAssertEqual(result.file, "normalised.mov")
    }
}

final class AudioShortcutTests: XCTestCase {
    func testFortyEightKilohertzPCMIsMeasuredButNotCopied() async throws {
        let folder = tempFolder("pcm48")
        let input = folder.appendingPathComponent("original.wav")
        try Generated.sineWAV(at: input, seconds: 1, sampleRate: 48_000, channels: 2, dbfs: -23)

        let result = try await AssetNormaliser().normalise(input, into: folder)

        XCTAssertNil(result.file)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("normalised.wav").path))
        XCTAssertEqual(try XCTUnwrap(result.loudness).integratedLUFS, -23, accuracy: 0.2)
        XCTAssertEqual(result.peaks, "peaks.bin")
        XCTAssertEqual(try XCTUnwrap(result.duration), 1, accuracy: 0.001)
    }

    func testOtherRatesAreRewritten() {
        let folder = tempFolder("pcm44")
        let input = folder.appendingPathComponent("original.wav")
        try? Generated.sineWAV(at: input, seconds: 0.2, sampleRate: 44_100)
        XCTAssertFalse(AudioNormaliser.canUseAsIs(input, format: .wav))
    }
}

final class LUTTests: XCTestCase {
    /// A 2-point .cube that swaps red and blue.
    func writeSwapLUT(to url: URL) throws {
        var lines = ["TITLE \"Swap\"", "LUT_3D_SIZE 2", "DOMAIN_MIN 0 0 0", "DOMAIN_MAX 1 1 1"]
        for b in 0..<2 { for g in 0..<2 { for r in 0..<2 { lines.append("\(b) \(g) \(r)") } } }
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    func testLUTsAreCheckedAndPreviewed() async throws {
        let folder = tempFolder("lut")
        let input = folder.appendingPathComponent("original.cube")
        try writeSwapLUT(to: input)

        let result = try await AssetNormaliser().normalise(input, into: folder)

        XCTAssertEqual(result.format, .cube)
        XCTAssertNil(result.file)
        XCTAssertNil(result.mediaKind)
        XCTAssertEqual(result.thumbnail, "thumbnail.jpg")
        let table = try CubeLUT.read(input)
        XCTAssertEqual(table.size, 2)
        XCTAssertEqual(table.data.count, 8 * 4 * 4)
        // The preview's right half went through the LUT: a pure red pixel
        // in the card's top-left corner comes out blue.
        let preview = try XCTUnwrap(CubeLUT.preview(table))
        XCTAssertEqual(preview.width, 512)
        let context = CGContext(data: nil, width: 512, height: 256, bitsPerComponent: 8, bytesPerRow: 512 * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.draw(preview, in: CGRect(x: 0, y: 0, width: 512, height: 256))
        let pixels = context.data!.bindMemory(to: UInt8.self, capacity: 512 * 256 * 4)
        let left = Array(UnsafeBufferPointer(start: pixels + 2 * 4, count: 3))
        let right = Array(UnsafeBufferPointer(start: pixels + (256 + 2) * 4, count: 3))
        XCTAssertGreaterThan(left[0], 200)
        XCTAssertLessThan(left[2], 60)
        XCTAssertLessThan(right[0], 60)
        XCTAssertGreaterThan(right[2], 200)
    }

    func testBrokenLUTsAreRefused() throws {
        let folder = tempFolder("badlut")
        let short = folder.appendingPathComponent("short.cube")
        try "LUT_3D_SIZE 4\n0 0 0\n1 1 1\n".write(to: short, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try CubeLUT.read(short))
        let oneD = folder.appendingPathComponent("oned.cube")
        try "LUT_1D_SIZE 2\n0 0 0\n1 1 1\n".write(to: oneD, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try CubeLUT.read(oneD))
    }
}
