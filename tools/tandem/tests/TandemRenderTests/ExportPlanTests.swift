import XCTest
import TandemCore
@testable import TandemRender

/// Presets set the quality (codec, bitrate, resolution class) and the
/// project sets the shape. The CLI, the API and the app's Export dialog all
/// resolve presets through `ExportPreset.plan(for:)`.
final class ExportPlanTests: XCTestCase {
    func canvas(_ width: Int, _ height: Int, fps: FrameRate = .fps30, formats: [OutputFormat] = []) -> ProjectSettings {
        ProjectSettings(width: width, height: height, frameRate: fps, alternateFormats: formats)
    }

    func size(_ plan: ExportPlan) -> String { "\(plan.width)x\(plan.height)" }

    func testLandscape1080p() throws {
        let hd = canvas(1920, 1080)
        XCTAssertEqual(ExportPreset.standard(for: hd).name, "YouTube 1080p", "the default follows the canvas")

        let youtube1080 = try ExportPreset.youtube1080.plan(for: hd)
        XCTAssertEqual(size(youtube1080), "1920x1080")
        XCTAssertEqual(youtube1080.codec, .h264)
        XCTAssertEqual(youtube1080.videoBitrate, 20_000_000)
        XCTAssertNil(youtube1080.format)
        XCTAssertEqual(youtube1080.warnings, [])
        XCTAssertEqual(youtube1080.summary, "1920x1080 H.264 at 20 Mbps")

        // Asking for 4K of a 1080p canvas upscales it, and says so.
        let youtube4K = try ExportPreset.youtube4K.plan(for: hd)
        XCTAssertEqual(size(youtube4K), "3840x2160")
        XCTAssertEqual(youtube4K.codec, .hevc)
        XCTAssertEqual(youtube4K.videoBitrate, 80_000_000)
        XCTAssertTrue(youtube4K.isUpscaled)
        XCTAssertEqual(youtube4K.warnings, ["YouTube 4K upscales the 1920x1080 canvas to 3840x2160, so it's no sharper than the canvas."])

        let review = try ExportPreset.review.plan(for: hd)
        XCTAssertEqual(size(review), "1280x720")
        XCTAssertEqual(review.videoBitrate, 5_000_000)
        XCTAssertEqual(review.warnings, [])
    }

    func testLandscape4KExportsAsBefore() throws {
        let uhd = canvas(3840, 2160)
        XCTAssertEqual(ExportPreset.standard(for: uhd).name, "YouTube 4K")

        let youtube4K = try ExportPreset.youtube4K.plan(for: uhd)
        XCTAssertEqual(youtube4K.summary, "3840x2160 HEVC at 80 Mbps")
        XCTAssertNil(youtube4K.format)
        XCTAssertEqual(youtube4K.warnings, [])

        let youtube1080 = try ExportPreset.youtube1080.plan(for: uhd)
        XCTAssertEqual(youtube1080.summary, "1920x1080 H.264 at 20 Mbps")
        XCTAssertEqual(youtube1080.warnings, [], "scaling down needs no warning")

        XCTAssertEqual(try ExportPreset.review.plan(for: uhd).summary, "1280x720 H.264 at 5 Mbps")
    }

    func testNativePortrait() throws {
        let portrait = canvas(1080, 1920)
        XCTAssertEqual(ExportPreset.standard(for: portrait).name, "YouTube 1080p", "1080x1920 is 1080p, not 4K")

        let youtube1080 = try ExportPreset.youtube1080.plan(for: portrait)
        XCTAssertEqual(youtube1080.summary, "1080x1920 H.264 at 20 Mbps", "the preset keeps the canvas's shape")
        XCTAssertNil(youtube1080.format)
        XCTAssertEqual(youtube1080.warnings, [])

        let youtube4K = try ExportPreset.youtube4K.plan(for: portrait)
        XCTAssertEqual(youtube4K.summary, "2160x3840 HEVC at 80 Mbps")
        XCTAssertEqual(youtube4K.warnings, ["YouTube 4K upscales the 1080x1920 canvas to 2160x3840, so it's no sharper than the canvas."])

        // The project is its own short: no portrait format needed.
        let short = try ExportPreset.short.plan(for: portrait)
        XCTAssertEqual(short.summary, "1080x1920 H.264 at 20 Mbps")
        XCTAssertNil(short.format, "renders the main canvas")
        XCTAssertEqual(short.preset.name, "Short 9:16")
        XCTAssertEqual(short.warnings, [])

        XCTAssertEqual(try ExportPreset.review.plan(for: portrait).summary, "720x1280 H.264 at 5 Mbps")
    }

    func testSquare() throws {
        let square = canvas(1080, 1080)
        XCTAssertEqual(ExportPreset.standard(for: square).name, "YouTube 1080p")

        // The bitrate is for a 16:9 frame of the class; a square has 56% of
        // its area, so it gets 56% of the bits for the same picture.
        let youtube1080 = try ExportPreset.youtube1080.plan(for: square)
        XCTAssertEqual(youtube1080.summary, "1080x1080 H.264 at 11.3 Mbps")
        XCTAssertEqual(youtube1080.videoBitrate, 11_300_000)

        let youtube4K = try ExportPreset.youtube4K.plan(for: square)
        XCTAssertEqual(youtube4K.summary, "2160x2160 HEVC at 45 Mbps")
        XCTAssertEqual(youtube4K.warnings.count, 1)

        XCTAssertEqual(try ExportPreset.review.plan(for: square).summary, "720x720 H.264 at 2.8 Mbps")

        // A square isn't 9:16, so there's no short to render yet.
        XCTAssertThrowsError(try ExportPreset.short.plan(for: square)) { error in
            XCTAssertEqual(error as? ExportPlanError, .noPortrait(width: 1080, height: 1080))
        }
    }

    func testLandscapeWithAPortraitFormat() throws {
        let both = canvas(3840, 2160, formats: [.portrait])
        XCTAssertEqual(ExportPreset.standard(for: both).name, "YouTube 4K", "the main canvas decides the default")
        XCTAssertEqual(try ExportPreset.youtube4K.plan(for: both).summary, "3840x2160 HEVC at 80 Mbps")
        XCTAssertNil(try ExportPreset.youtube4K.plan(for: both).format)

        let short = try ExportPreset.short.plan(for: both)
        XCTAssertEqual(short.format, "portrait")
        XCTAssertEqual(short.summary, "1080x1920 H.264 at 20 Mbps")
        XCTAssertEqual(short.preset.format, "portrait")
        XCTAssertEqual(short.warnings, [])

        // Any preset renders the portrait format when asked, at its quality,
        // and the default for that format is 1080p.
        XCTAssertEqual(ExportPreset.standard(for: both, format: "portrait").name, "YouTube 1080p")
        XCTAssertEqual(try ExportPreset.youtube1080.plan(for: both, format: "portrait").summary, "1080x1920 H.264 at 20 Mbps")
        let upscaled = try ExportPreset.youtube4K.plan(for: both, format: "portrait")
        XCTAssertEqual(upscaled.summary, "2160x3840 HEVC at 80 Mbps")
        XCTAssertEqual(upscaled.warnings, ["YouTube 4K upscales the 1080x1920 Short (9:16) format to 2160x3840, so it's no sharper than the format."])

        // "main" asks for the canvas even from the short preset.
        XCTAssertNil(try ExportPreset.short.plan(for: both, format: "main").format)
    }

    func testTheShortPresetSaysHowToMakeAPortraitFrame() {
        XCTAssertThrowsError(try ExportPreset.short.plan(for: canvas(3840, 2160))) { error in
            XCTAssertEqual(error as? ExportPlanError, .noPortrait(width: 3840, height: 2160))
            XCTAssertEqual("\(error)", """
            This 3840x2160 project has no 9:16 frame for the short: its canvas isn't 9:16 and it has no portrait \
            format. Make one with `tandem short --apply` (screen on top, camera below), or add the portrait format \
            with updateSettings (alternateFormats) and place clips in it with setFormatLayout. To export the canvas \
            as it is, use --preset youtube4k.
            """)
            XCTAssertEqual((error as? LocalizedError)?.errorDescription, "\(error)")
        }
        // A 1080p landscape canvas is pointed at the 1080p preset.
        XCTAssertThrowsError(try ExportPreset.short.plan(for: canvas(1920, 1080))) { error in
            XCTAssertTrue("\(error)".hasSuffix("To export the canvas as it is, use --preset youtube1080."), "\(error)")
        }
        // Asking for the portrait format by name says the same.
        XCTAssertThrowsError(try ExportPreset.youtube1080.plan(for: canvas(3840, 2160), format: "portrait")) { error in
            XCTAssertEqual(error as? ExportPlanError, .noPortrait(width: 3840, height: 2160))
        }
    }

    func testAnUnknownFormatListsTheOnesThereAre() {
        XCTAssertThrowsError(try ExportPreset.youtube1080.plan(for: canvas(3840, 2160, formats: [.portrait]), format: "square")) { error in
            XCTAssertEqual("\(error)", "No output format \"square\". This project has: main, portrait.")
        }
    }

    func testHighFrameRatesGetHalfAsMuchAgain() throws {
        // YouTube's table: 8 Mbps for 1080p at 24 to 30 fps, 12 at 48 to 60.
        XCTAssertEqual(try ExportPreset.youtube1080.plan(for: canvas(1920, 1080, fps: .fps60)).videoBitrate, 30_000_000)
        XCTAssertEqual(try ExportPreset.youtube1080.plan(for: canvas(1920, 1080, fps: FrameRate(60_000, 1001))).videoBitrate, 30_000_000)
        XCTAssertEqual(try ExportPreset.youtube4K.plan(for: canvas(3840, 2160, fps: FrameRate(50))).videoBitrate, 120_000_000)
        XCTAssertEqual(try ExportPreset.youtube1080.plan(for: canvas(1920, 1080, fps: .fps25)).videoBitrate, 20_000_000)
        XCTAssertEqual(try ExportPreset.youtube1080.plan(for: canvas(1920, 1080, fps: FrameRate(30_000, 1001))).videoBitrate, 20_000_000)
    }

    func testOddSizes() throws {
        // Anything over 1080 on its short side defaults to 4K: a Retina
        // screen-sized canvas is upscaled a little, a 5K one scaled down.
        let retina = canvas(3200, 1800)
        XCTAssertEqual(ExportPreset.standard(for: retina).name, "YouTube 4K")
        let fromRetina = try ExportPreset.youtube4K.plan(for: retina)
        XCTAssertEqual(size(fromRetina), "3840x2160")
        XCTAssertEqual(fromRetina.warnings.count, 1)
        XCTAssertEqual(size(try ExportPreset.youtube1080.plan(for: retina)), "1920x1080")

        let fiveK = canvas(5120, 2880)
        XCTAssertEqual(ExportPreset.standard(for: fiveK).name, "YouTube 4K")
        XCTAssertEqual(try ExportPreset.youtube4K.plan(for: fiveK).summary, "3840x2160 HEVC at 80 Mbps")

        // 1080 or less defaults to 1080p, upscaling a small canvas.
        let small = canvas(1280, 720)
        XCTAssertEqual(ExportPreset.standard(for: small).name, "YouTube 1080p")
        XCTAssertEqual(try ExportPreset.youtube1080.plan(for: small).warnings.count, 1)
        XCTAssertEqual(try ExportPreset.review.plan(for: small).warnings, [])

        // Sizes stay even, as 4:2:0 video needs, and the shape is kept.
        let ultrawide = try ExportPreset.youtube1080.plan(for: canvas(2560, 1080))
        XCTAssertEqual(ultrawide.summary, "2560x1080 H.264 at 26.7 Mbps")
        XCTAssertEqual(size(try ExportPreset.review.plan(for: canvas(1001, 1999))), "720x1438")
    }

    func testAPlanIsFinal() throws {
        // The planned preset carries its size, format and bitrate, so the
        // exporter planning it again changes nothing.
        let settings = canvas(1080, 1080, fps: .fps60)
        let plan = try ExportPreset.youtube1080.plan(for: settings)
        XCTAssertEqual(plan.preset.width, 1080)
        XCTAssertEqual(plan.preset.height, 1080)
        XCTAssertNil(plan.preset.resolution)
        XCTAssertEqual(plan.preset.videoBitrate, 16_900_000)
        XCTAssertEqual(plan.preset.format, "main")
        let again = try plan.preset.plan(for: settings)
        XCTAssertEqual(again.preset, plan.preset)
        XCTAssertEqual(again.summary, plan.summary)

        let short = try ExportPreset.short.plan(for: canvas(3840, 2160, formats: [.portrait])).preset
        XCTAssertEqual(try short.plan(for: canvas(3840, 2160, formats: [.portrait])).preset, short)
    }

    func testCustomPresetsKeepTheirNumbers() throws {
        // No resolution: the canvas's own size, the bitrate as given.
        let plain = ExportPreset(name: "Test", codec: .h264, videoBitrate: 4_000_000)
        XCTAssertEqual(try plain.plan(for: canvas(320, 180, fps: .fps60)).summary, "320x180 H.264 at 4 Mbps")
        // An exact size wins, whatever the canvas's shape.
        let exact = ExportPreset(name: "Exact", width: 160, height: 90, codec: .h264, videoBitrate: 1_000_000)
        XCTAssertEqual(try exact.plan(for: canvas(1080, 1920)).summary, "160x90 H.264 at 1 Mbps")
        // A custom format keeps its own size.
        let formats = [OutputFormat(id: "portrait", name: "Short", width: 180, height: 320)]
        let format = try ExportPreset(name: "Test", codec: .h264, videoBitrate: 4_000_000, format: "portrait").plan(for: canvas(320, 180, formats: formats))
        XCTAssertEqual(format.summary, "180x320 H.264 at 4 Mbps")
        XCTAssertEqual(format.format, "portrait")
    }

    func testBitrateText() {
        XCTAssertEqual(ExportPlan.megabits(20_000_000), "20 Mbps")
        XCTAssertEqual(ExportPlan.megabits(11_300_000), "11.3 Mbps")
        XCTAssertEqual(ExportPlan.megabits(320_000), "0.3 Mbps")
    }
}
