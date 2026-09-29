import AVFoundation
import CoreImage
import XCTest
import TandemCore
import TandemMedia
@testable import TandemRender

/// The section card through the real planner and composer, checked against
/// the mockup (`~/dev/me/tandem-research/title-cards`): colours, where the
/// chip, title, subtitle and bars sit (measured from Chrome's render of the
/// mockup's CSS at 1920x1080), and the bands and wipes at every point of
/// rows above and below the words.
final class SectionCardRenderTests: XCTestCase {
    static let props = SectionCard.Props(title: "Methodology", subtitle: "Let's keep it fair", number: "01", total: 3)
    static let background = [20, 20, 24]
    static let accent = [243, 176, 28]
    static let red = [238, 52, 47]
    static let purple = [141, 38, 118]

    /// A red shot until the cut at 2.5 s and a blue one after it, under a
    /// card from 1 s to 4.2 s.
    func harness(width: Int, height: Int, props: SectionCard.Props = props) -> CompositorHarness {
        let before = Clip(id: "clip_before", content: .media(mediaID: "med_red"), start: .zero, duration: t(2.5))
        let after = Clip(id: "clip_after", content: .media(mediaID: "med_blue"), start: t(2.5), duration: t(3.5))
        let card = Clip(id: "clip_card", content: SectionCard.content(props), start: t(1), duration: SectionCard.defaultDuration)
        let project = Project(
            name: "Card",
            settings: ProjectSettings(width: width, height: height, frameRate: .fps30),
            media: [redMedia, blueMedia],
            videoTracks: [Track(kind: .video, name: "V1", clips: [before, after]), Track(kind: .video, name: "Graphics", rippleMode: .follow).with([card])]
        )
        var harness = CompositorHarness(project)
        harness.pictures = ["med_red": solid(1, 0, 0), "med_blue": solid(0, 0, 1)]
        return harness
    }

    /// The box around pixels that pass `test` (given r, g, b), y down.
    func bounds(_ bitmap: Bitmap, in rect: CGRect, _ test: ([Int]) -> Bool) -> CGRect? {
        var minX = Int.max, minY = Int.max, maxX = Int.min, maxY = Int.min
        bitmap.bytes.withUnsafeBufferPointer { bytes in
            var pixel = [0, 0, 0]
            for y in Int(rect.minY)..<Int(rect.maxY) {
                var i = (y * bitmap.width + Int(rect.minX)) * 4
                for x in Int(rect.minX)..<Int(rect.maxX) {
                    pixel[0] = Int(bytes[i]); pixel[1] = Int(bytes[i + 1]); pixel[2] = Int(bytes[i + 2])
                    if test(pixel) {
                        minX = min(minX, x); maxX = max(maxX, x)
                        minY = min(minY, y); maxY = max(maxY, y)
                    }
                    i += 4
                }
            }
        }
        guard minX <= maxX else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    func near(_ pixel: [Int], _ colour: [Int], _ tolerance: Int = 24) -> Bool {
        (0..<3).allSatisfy { abs(pixel[$0] - colour[$0]) <= tolerance }
    }

    /// `expected` is at 1920 wide, scaled to the frame; `tolerance` is in
    /// the frame's pixels.
    func assertBox(_ box: CGRect?, _ expected: CGRect, scale: CGFloat, tolerance: CGFloat, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let box else { return XCTFail("no \(what)", file: file, line: line) }
        let want = CGRect(x: expected.minX * scale, y: expected.minY * scale, width: expected.width * scale, height: expected.height * scale)
        for (got, wanted, edge) in [(box.minX, want.minX, "left"), (box.maxX, want.maxX, "right"), (box.minY, want.minY, "top"), (box.maxY, want.maxY, "bottom")] {
            XCTAssertEqual(got, wanted, accuracy: tolerance, "\(what) \(edge)", file: file, line: line)
        }
    }

    // MARK: - The hold

    /// Where Chrome drew the mockup's card (B with D's progress row) at
    /// 1920x1080, ink edges inclusive-exclusive, from
    /// `title-cards/tandem/ref-set0-t1.60.png`.
    static let chrome = (
        chip: CGRect(x: 920, y: 357, width: 80, height: 52),
        title: CGRect(x: 475, y: 444, width: 973, height: 158),
        subtitle: CGRect(x: 720, y: 645, width: 481, height: 25),
        litBar: CGRect(x: 804, y: 716, width: 96, height: 7)
    )

    func testTheHoldMatchesTheMockupAt1080pAnd4K() {
        for (width, height) in [(1920, 1080), (3840, 2160)] {
            let scale = CGFloat(width) / 1920
            let frame = harness(width: width, height: height).render(at: t(2.6))
            assertColor(frame[10, 10], Self.background, tolerance: 1, "the card covers the frame")
            assertColor(frame[width - 10, height - 10], Self.background, tolerance: 1)
            let upper = CGRect(x: 0, y: 0, width: width, height: height * 45 / 100)
            let chip = bounds(frame, in: upper) { self.near($0, Self.accent, 8) }
            assertBox(chip, Self.chrome.chip, scale: scale, tolerance: 1.5 * scale, "chip at \(width)")
            let white = bounds(frame, in: CGRect(x: 0, y: 0, width: width, height: height)) { $0[0] > 200 && $0[1] > 200 && $0[2] > 200 }
            assertBox(white, Self.chrome.title, scale: scale, tolerance: 2 * scale, "title at \(width)")
            let subtitleRows = CGRect(x: 0, y: CGFloat(height) * 0.58, width: CGFloat(width), height: CGFloat(height) * 0.06)
            assertBox(bounds(frame, in: subtitleRows) { self.near($0, Self.accent, 60) && $0[0] > 150 }, Self.chrome.subtitle, scale: scale, tolerance: 2 * scale, "subtitle at \(width)")
            let barRows = CGRect(x: 0, y: CGFloat(height) * 0.65, width: CGFloat(width), height: CGFloat(height) * 0.03)
            assertBox(bounds(frame, in: barRows) { self.near($0, Self.accent, 12) }, Self.chrome.litBar, scale: scale, tolerance: 1.5 * scale, "lit bar at \(width)")
            // The two unlit bars: white at 28% over the card.
            let unlit = frame[Int(959 * scale), Int(719 * scale)]
            assertColor(unlit, [86, 86, 89], tolerance: 3, "an unlit bar")
        }
    }

    func testFontsShipWithTandem() {
        XCTAssertTrue(CardFonts.bundled, "Anton, Instrument Sans and JetBrains Mono load from the resource bundle")
        XCTAssertEqual(CTFontCopyFamilyName(CardFonts.title(40)) as String, "Anton")
        XCTAssertEqual(CTFontCopyFamilyName(CardFonts.sans(20, weight: 600)) as String, "Instrument Sans")
        XCTAssertEqual(CTFontCopyFamilyName(CardFonts.mono(20, weight: 700)) as String, "JetBrains Mono")
    }

    // MARK: - The wipes

    /// Every pixel of two rows (above and below the words) at moments in
    /// both sweeps, against what the motion says should be there: the shot
    /// below, the card, or the band on top. Pixels by an edge are skipped.
    func testTheBandsWipeTheCardInAndOut() {
        let width = 960, height = 540
        let h = harness(width: width, height: height)
        let w = Double(width)
        let motion = SectionCard.Motion(duration: 3.2, aspect: Double(height) / w)
        let bands = [Self.accent, Self.red, Self.purple]
        for clipTime in [0.1, 0.3, 0.45, 0.6, 0.8, 2.4, 2.6, 2.9, 3.1] {
            let frame = h.render(at: t(1 + clipTime))
            let shot = 1 + clipTime < 2.5 ? [255, 0, 0] : [0, 0, 255]
            var checked = 0
            for y in [height / 10, height * 9 / 10] {
                let v = Double(y) / w
                var edges: [Double] = []
                for (_, band) in motion.bands(at: clipTime) { edges += [band.leftEdge(atY: v) * w, band.rightEdge(atY: v) * w] }
                let reveal = motion.reveal(at: clipTime)
                for band in [reveal.before, reveal.after].compactMap({ $0 }) { edges.append(band.leftEdge(atY: v) * w) }
                for x in stride(from: 1, to: width - 1, by: 3) {
                    let px = Double(x) + 0.5
                    if edges.contains(where: { abs($0 - px) < 2.5 }) { continue }
                    var expected = shot
                    if !reveal.hidden {
                        var card = true
                        if let band = reveal.before, px >= band.leftEdge(atY: v) * w { card = false }
                        if let band = reveal.after, px <= band.leftEdge(atY: v) * w { card = false }
                        if card { expected = Self.background }
                    }
                    for (index, band) in motion.bands(at: clipTime) where px > band.leftEdge(atY: v) * w && px < band.rightEdge(atY: v) * w {
                        expected = bands[index]
                    }
                    assertColor(frame[x, y], expected, tolerance: 2, "at \(x),\(y) \(clipTime) s into the card")
                    checked += 1
                }
            }
            XCTAssertGreaterThan(checked, 400)
        }
    }

    func testBeforeAndAfterTheCardTheShotsShowThrough() {
        let h = harness(width: 480, height: 270)
        assertColor(h.render(at: t(0.99))[240, 135], [255, 0, 0], tolerance: 0, "before the card")
        assertColor(h.render(at: t(1.0))[400, 135], [255, 0, 0], tolerance: 0, "its first frame: the bands are still off to the left")
        assertColor(h.render(at: t(4.2))[240, 135], [0, 0, 255], tolerance: 0, "after it")
        assertColor(h.render(at: t(4.19))[20, 135], [0, 0, 255], tolerance: 2, "its last frame shows the next shot behind the last band")
    }

    // MARK: - Layout

    func testLongTitlesWrapOntoBalancedLines() {
        let props = SectionCard.Props(title: "Low change cost and easy to reverse", subtitle: "Just do it & reverse", number: "01", total: 14, kicker: "Tip")
        let layout = SectionCardLayout(props, size: CGSize(width: 1920, height: 1080))
        let titles = layout.texts.filter { $0.role == .title }
        XCTAssertEqual(titles.count, 2)
        let widths = titles.map(\.width)
        XCTAssertLessThan(widths.max()! / widths.min()!, 1.4, "balanced, not one long line and a short one")
        XCTAssertLessThanOrEqual(widths.max()!, 84 * 19.2)
        XCTAssertEqual(titles.map(\.string).joined(separator: " "), "LOW CHANGE COST AND EASY TO REVERSE")
        for line in titles { XCTAssertEqual(line.x + line.width / 2, 960, accuracy: 0.5, "centred") }
        XCTAssertEqual(titles[1].baseline - titles[0].baseline, 0.95 * 9.4 * 19.2, accuracy: 0.01, "line height .95")
        // The block stays in the middle of the frame.
        XCTAssertEqual(layout.bounds.midY, 540, accuracy: 40)
        // Tip 1 of 14: the kicker beside the chip, the proportional bar and its count.
        XCTAssertEqual(layout.texts.first { $0.role == .kicker }?.string, "TIP 1 OF 14")
        XCTAssertEqual(layout.texts.first { $0.role == .count }?.string, "1 / 14")
        XCTAssertEqual(layout.texts.first { $0.role == .subtitle }?.string, "JUST DO IT & REVERSE")
        let bars = layout.boxes.filter { $0.rect.height < 10 }
        XCTAssertEqual(bars.count, 2)
        XCTAssertEqual(bars.map(\.rect.width).reduce(0, +), 30 * 19.2, accuracy: 0.01, "30cqw between them")
        XCTAssertEqual(bars[0].rect.width, 30 * 19.2 / 14, accuracy: 0.01, "1 of 14 lit")
        // A chip and a kicker share a row, centred on each other.
        let chip = layout.boxes[0].rect
        XCTAssertEqual(chip.height, 2.7 * 19.2, accuracy: 0.01)
        let kicker = layout.texts.first { $0.role == .kicker }!
        XCTAssertEqual(kicker.x - chip.maxX, 1.4 * 19.2, accuracy: 0.01)
    }

    func testMissingPartsAreLeftOut() {
        let bare = SectionCardLayout(SectionCard.Props(title: "Results"), size: CGSize(width: 1920, height: 1080))
        XCTAssertEqual(bare.texts.map(\.role), [.title])
        XCTAssertTrue(bare.boxes.isEmpty)
        XCTAssertEqual(bare.bounds.midY, 540, accuracy: 60, "the title alone sits in the middle")
        let empty = SectionCardLayout(SectionCard.Props(), size: CGSize(width: 1920, height: 1080))
        XCTAssertTrue(empty.texts.isEmpty)
    }

    func testAnyFrameSizeDraws() {
        for (width, height) in [(1080, 1920), (64, 36), (3840, 2160)] {
            for time in [0.0, 0.3, 1.6, 2.9] {
                let image = SectionCardArt.image(Self.props, size: CGSize(width: width, height: height), time: time)
                XCTAssertEqual(image?.width, width)
                XCTAssertEqual(image?.height, height)
            }
        }
        XCTAssertNil(SectionCardArt.image(Self.props, size: CGSize(width: 1, height: 1), time: 1))
    }

    /// A 4K frame during a wipe is drawn from scratch; the hold is drawn
    /// once and reused.
    func testDrawingIsQuickEnoughForPlayback() {
        let size = CGSize(width: 3840, height: 2160)
        _ = SectionCardRenderer.shared.image(Self.props, size: size, time: 0.3, duration: 3.2)
        let start = Date()
        for time in stride(from: 0.0, to: 0.9, by: 0.1) {
            _ = SectionCardRenderer.shared.image(Self.props, size: size, time: time, duration: 3.2)
        }
        let perFrame = Date().timeIntervalSince(start) / 9
        print("Section card: \(String(format: "%.1f", perFrame * 1000)) ms a 4K frame during the wipe")
        XCTAssertLessThan(perFrame, 0.2)
        let hold = SectionCardRenderer.shared.image(Self.props, size: size, time: 1.5, duration: 3.2)
        XCTAssertTrue(hold === SectionCardRenderer.shared.image(Self.props, size: size, time: 2.0, duration: 3.2), "the hold is drawn once")
    }

    // MARK: - Through AVFoundation

    /// A frame grab and an export of a card over nothing: the same card.
    func testFrameGrabsAndExportsShowTheCard() async throws {
        let media = try TestMedia()
        let card = Clip(id: "clip_card", content: SectionCard.content(Self.props), start: .zero, duration: SectionCard.defaultDuration)
        let project = Project(
            name: "Card", settings: ProjectSettings(width: 640, height: 360, frameRate: .fps30),
            videoTracks: [Track(kind: .video, name: "Graphics", clips: [card])]
        )
        let context = RenderContext(project: project, folder: media.projectFolder)
        let renderer = FrameRenderer(context: context)
        let warnings = try await renderer.warnings()
        XCTAssertEqual(warnings, [], "section cards render")
        let grab = Bitmap(try await renderer.image(at: t(1.6)))
        assertColor(grab[5, 5], Self.background, tolerance: 1)
        let chip = bounds(grab, in: CGRect(x: 0, y: 0, width: 640, height: 160)) { self.near($0, Self.accent, 8) }
        assertBox(chip, Self.chrome.chip, scale: 1.0 / 3, tolerance: 1.5, "chip in the grab")

        let out = media.folder.appendingPathComponent("exports/card.mp4")
        let preset = ExportPreset(name: "Test", codec: .h264, videoBitrate: 8_000_000, loudnessTarget: nil, truePeakCeiling: nil)
        _ = try await Exporter(context: context, preset: preset, output: out).run()
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: out))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let exported = Bitmap(try await generator.image(at: CMTime(seconds: 1.6, preferredTimescale: 600)).image)
        assertColor(exported[5, 5], Self.background, tolerance: 4, "the card in the export")
        let exportedChip = bounds(exported, in: CGRect(x: 0, y: 0, width: 640, height: 160)) { self.near($0, Self.accent, 16) }
        // 4:2:0 chroma at a third of the size softens the edges a pixel or two.
        assertBox(exportedChip, Self.chrome.chip, scale: 1.0 / 3, tolerance: 3, "chip in the export")
    }

    func testOtherGraphicTemplatesStillWarn() {
        let clip = Clip(content: .graphic(GraphicContent(template: "remotion:BarChart")), start: .zero, duration: t(2))
        let project = smallProject(video: [Track(kind: .video, name: "V1", clips: [clip])], media: [])
        let plan = RenderPlanner.plan(project, format: nil, assets: nil)
        XCTAssertEqual(plan.warnings, ["Graphic clips aren't rendered yet (remotion:BarChart)."])
        let card = Clip(content: SectionCard.content(Self.props), start: .zero, duration: t(3.2))
        let cardPlan = RenderPlanner.plan(smallProject(video: [Track(kind: .video, name: "V1", clips: [card])], media: []), format: nil, assets: nil)
        XCTAssertEqual(cardPlan.warnings, [])
        XCTAssertEqual(cardPlan.instructions.first?.stack.count, 1)
    }
}

private extension Track {
    func with(_ clips: [Clip]) -> Track {
        var track = self
        track.clips = clips
        return track
    }
}

