import CoreImage
import XCTest
import TandemCore
import TandemMedia
@testable import TandemRender

final class TextTests: XCTestCase {
    func request(_ text: String, size: Double = 64, background: [Double]? = nil, visible: Int? = nil, highlight: Range<Int>? = nil, firstLineScale: Double = 1) -> TextRenderer.Request {
        TextRenderer.Request(
            text: text, font: "SF Pro Display", size: size, weight: 800, color: [1, 1, 1, 1],
            strokeColor: nil, strokeWidth: 0, backgroundColor: background, alignment: "center",
            shadow: false, lineSpacing: 0, maxWidth: 2000, highlight: highlight,
            highlightColor: [1, 0.84, 0.2, 1], visibleLength: visible, firstLineScale: firstLineScale, firstLineColor: nil
        )
    }

    func opaquePixels(_ image: CIImage) -> Int {
        let bitmap = Bitmap(image, size: image.extent.size)
        return bitmap.bytes.enumerated().filter { $0.offset % 4 == 3 && $0.element > 128 }.count
    }

    func testPresetsCoverMikesFourTitleStyles() {
        for id in ["label", "callout", "sectionHeader", "version"] {
            XCTAssertNotNil(TitlePresets.preset(id), id)
        }
        XCTAssertNotNil(TitlePresets.preset("CALLOUT"))
        XCTAssertNil(TitlePresets.preset("nope"))
    }

    func testPresetMergesWithClipOverrides() {
        let callout = ResolvedText(TextContent(text: "14 tips", preset: "callout"))
        XCTAssertEqual(callout.text, "14 TIPS")
        XCTAssertEqual(callout.style.backgroundColor, TitlePresets.accent)
        XCTAssertEqual(callout.animationIn, .pop)
        XCTAssertEqual(callout.animationDuration, Time(seconds: 0.35))

        var own = TextStyle()
        own.color = RGBA(r: 1, g: 0, b: 0)
        own.size = 120
        let custom = ResolvedText(TextContent(text: "Reason 1", preset: "callout", style: own, animationIn: "fade"))
        XCTAssertEqual(custom.style.color, RGBA(r: 1, g: 0, b: 0))
        XCTAssertEqual(custom.style.size, 120)
        XCTAssertEqual(custom.style.backgroundColor, TitlePresets.accent)
        XCTAssertEqual(custom.animationIn, .fade)

        let plain = ResolvedText(TextContent(text: "Hi"))
        XCTAssertEqual(plain.text, "Hi")
        XCTAssertNil(plain.animationIn)
    }

    func testAnimationNames() {
        XCTAssertEqual(TextAnimation(name: "popIn"), .pop)
        XCTAssertEqual(TextAnimation(name: "fadeOut"), .fade)
        XCTAssertEqual(TextAnimation(name: "slideUp"), .slideUp)
        XCTAssertEqual(TextAnimation(name: "typewriter"), .typewriter)
        XCTAssertNil(TextAnimation(name: "wobble"))
    }

    func testAnimationStates() {
        let pop = ResolvedText(TextContent(text: "x", animationIn: "pop", animationOut: "fade", animationDuration: t(0.4)))
        let d = t(3)
        XCTAssertEqual(TextAnimationState.at(.zero, clipDuration: d, text: pop).scale, 0, accuracy: 1e-9)
        // It overshoots past full size before settling.
        let peak = stride(from: 0.0, through: 0.4, by: 0.02).map { TextAnimationState.at(t($0), clipDuration: d, text: pop).scale }.max()!
        XCTAssertGreaterThan(peak, 1.05)
        XCTAssertEqual(TextAnimationState.at(t(1.5), clipDuration: d, text: pop), TextAnimationState())
        XCTAssertEqual(TextAnimationState.at(t(2.8), clipDuration: d, text: pop).opacity, 0.5, accuracy: 0.01)

        let slide = ResolvedText(TextContent(text: "x", animationIn: "slideUp", animationDuration: t(0.5)))
        XCTAssertGreaterThan(TextAnimationState.at(.zero, clipDuration: d, text: slide).offsetY, 0.05)
        let typing = ResolvedText(TextContent(text: "x", animationIn: "typewriter", animationDuration: t(1)))
        XCTAssertEqual(TextAnimationState.at(t(0.5), clipDuration: d, text: typing).visibleFraction, 0.5, accuracy: 1e-9)
    }

    func testCaptionWordsAndHighlightRanges() {
        let words = [
            TimedWord(text: "Convex", start: t(0), end: t(0.4)),
            TimedWord(text: "is", start: t(0.5), end: t(0.6)),
            TimedWord(text: "fast", start: t(0.7), end: t(1))
        ]
        let caption = ResolvedText(TextContent(text: "ignored", preset: "caption", words: words))
        XCTAssertEqual(caption.text, "Convex is fast")
        XCTAssertEqual(caption.currentWord(at: t(0.2)), 0)
        XCTAssertEqual(caption.currentWord(at: t(0.45)), 0)
        XCTAssertEqual(caption.currentWord(at: t(0.8)), 2)
        XCTAssertEqual(caption.utf16Range(ofWord: 2), 10..<14)
    }

    func testDrawsTextWithPaddingForEffects() {
        let plain = TextRenderer.shared.image(request("HELLO"))!
        XCTAssertGreaterThan(plain.extent.width, 150)
        XCTAssertGreaterThan(opaquePixels(plain), 500)
        let boxed = TextRenderer.shared.image(request("HELLO", background: [1, 0.8, 0.16, 1]))!
        XCTAssertGreaterThan(boxed.extent.width, plain.extent.width)
        XCTAssertNil(TextRenderer.shared.image(request("")))
    }

    func testTwoLineTitlesAreTaller() {
        let one = TextRenderer.shared.image(request("CURSOR DOCS"))!
        let two = TextRenderer.shared.image(request("TIP 1\nCURSOR DOCS", firstLineScale: 0.55))!
        XCTAssertGreaterThan(two.extent.height, one.extent.height * 1.4)
    }

    func testLongTextWraps() {
        var r = request(String(repeating: "word ", count: 40))
        r.maxWidth = 600
        let image = TextRenderer.shared.image(r)!
        XCTAssertLessThanOrEqual(image.extent.width, 640)
        XCTAssertGreaterThan(image.extent.height, 200)
    }

    func testTypewriterShowsPartOfTheText() {
        let full = opaquePixels(TextRenderer.shared.image(request("TYPEWRITER"))!)
        let half = opaquePixels(TextRenderer.shared.image(request("TYPEWRITER", visible: 5))!)
        XCTAssertLessThan(half, full * 3 / 4)
        XCTAssertGreaterThan(half, full / 4)
    }

    func testHighlightedWordIsDrawnInTheHighlightColour() {
        let image = TextRenderer.shared.image(request("AAA BBB", highlight: 4..<7))!
        let bitmap = Bitmap(image, size: image.extent.size)
        var yellowOnRight = 0, yellowOnLeft = 0
        for y in 0..<bitmap.height {
            for x in 0..<bitmap.width {
                let p = bitmap[x, y]
                if p[3] > 200 && p[0] > 200 && p[2] < 120 {
                    if x > bitmap.width / 2 { yellowOnRight += 1 } else { yellowOnLeft += 1 }
                }
            }
        }
        XCTAssertGreaterThan(yellowOnRight, 100)
        XCTAssertEqual(yellowOnLeft, 0)
    }

    func testMissingFontsFallBackToTheSystemFont() {
        let font = TextRenderer.makeFont("Definitely Not A Font", size: 40, weight: 900)
        XCTAssertNotEqual(CTFontCopyFamilyName(font) as String, "Helvetica")
        let helvetica = TextRenderer.makeFont("Helvetica Neue", size: 40, weight: 700)
        XCTAssertEqual(CTFontCopyFamilyName(helvetica) as String, "Helvetica Neue")
        XCTAssertEqual(TextRenderer.weightTrait(800), 0.56, accuracy: 1e-6)
        XCTAssertEqual(TextRenderer.weightTrait(450), 0.115, accuracy: 1e-6)
    }

    func testTextLayerInAFrame() {
        let title = Clip(id: "clip_t", content: .text(TextContent(text: "Section two", preset: "label")), start: .zero, duration: t(3))
        let project = smallProject(video: [Track(kind: .video, name: "Text", clips: [title])], media: [])
        let h = CompositorHarness(project)
        let settled = h.render(at: t(1.5))
        XCTAssertGreaterThan(settled.litPixels(in: CGRect(x: 60, y: 70, width: 200, height: 40)), 150)
        XCTAssertEqual(settled.litPixels(in: CGRect(x: 0, y: 0, width: 40, height: 40)), 0)
        // Fading in at the very start.
        XCTAssertLessThan(h.render(at: .zero).litPixels(), settled.litPixels() / 4)
    }

    func testPopCalloutStartsSmall() {
        let callout = Clip(id: "clip_t", content: .text(TextContent(text: "14 tips", preset: "callout")), start: .zero, duration: t(3))
        let h = CompositorHarness(smallProject(video: [Track(kind: .video, name: "Text", clips: [callout])], media: []))
        let early = h.render(at: t(0.03)).litPixels()
        let settled = h.render(at: t(1.5)).litPixels()
        XCTAssertLessThan(early, settled / 2)
    }
}
