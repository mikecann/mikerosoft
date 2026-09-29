import XCTest
@testable import TandemApp
@testable import TandemCore
import TandemRender

/// The Text inspector's style edits, applied the way it applies them.
final class TextStyleEditsTests: XCTestCase {
    /// A title on the fixture's Text track, and a way to patch its style.
    struct Title {
        let fixture: AppFixture

        init(preset: String?) throws {
            fixture = try AppFixture()
            try fixture.apply(EditBatch(label: "Title", commands: [
                .insertClip(trackID: fixture.track("Text").id, clip: Clip(id: "clip_title", content: .text(TextContent(text: "14 tips", preset: preset)), start: t(2), duration: t(3)), mode: .overwrite)
            ]))
        }

        var text: TextContent {
            guard case .text(let text) = fixture.project.clip("clip_title")!.content else { fatalError("not text") }
            return text
        }

        var drawn: TextStyle.Resolved { TitlePresets.style(for: text) }

        func set(_ fields: [String: JSONValue]) throws {
            try fixture.apply(EditBatch(label: "Style", commands: [
                .updateClip(clipID: "clip_title", patch: .object(["content": .object(["text": .object(["style": .object(fields)])])]))
            ]))
        }
    }

    func testSwitchingOffAPresetsBoxAndShadowAndGoingBack() throws {
        let callout = try Title(preset: "callout")
        XCTAssertNotNil(callout.drawn.backgroundColor)
        try callout.set(TextStyleEdits.noBackground(preset: TitlePresets.presetStyle("callout")))
        try callout.set(["shadow": .bool(false)])
        XCTAssertNil(callout.drawn.backgroundColor, "a see-through box beats the preset's")
        XCTAssertFalse(callout.drawn.shadow)
        XCTAssertEqual(callout.text.style.setFields, ["backgroundColor", "shadow"], "both marked as the clip's own")

        try callout.set(TextStyleEdits.reset(["backgroundColor", "shadow"]))
        XCTAssertTrue(callout.text.style.isEmpty)
        XCTAssertEqual(callout.drawn, TitlePresets.presetStyle("callout"), "back to the preset")
    }

    func testNoBoxOnATitleWhosePresetHasNoneJustClearsTheClips() throws {
        let label = try Title(preset: "label")
        try label.set(["backgroundColor": ParamValue.color(RGBA(r: 1, g: 0, b: 0)).json])
        try label.set(TextStyleEdits.noBackground(preset: TitlePresets.presetStyle("label")))
        XCTAssertTrue(label.text.style.isEmpty)
        XCTAssertNil(label.drawn.backgroundColor)
    }

    func testAnOutlineGetsAColourWhenItHasNone() throws {
        let plain = try Title(preset: nil)
        try plain.set(TextStyleEdits.outline(width: 6, current: plain.drawn))
        XCTAssertTrue(plain.drawn.hasOutline)
        XCTAssertEqual(plain.drawn.strokeColor, .black)

        let caption = try Title(preset: "caption")
        XCTAssertEqual(Set(TextStyleEdits.outline(width: 9, current: caption.drawn).keys), ["strokeWidth"], "the caption's black stays the preset's")
        try caption.set(TextStyleEdits.outline(width: 0, current: caption.drawn))
        XCTAssertFalse(caption.drawn.hasOutline, "0 switches the caption's outline off")
    }

    func testLowerCaseOnALabel() throws {
        let label = try Title(preset: "label")
        XCTAssertTrue(label.drawn.uppercase)
        try label.set(["uppercase": .bool(false)])
        XCTAssertFalse(label.drawn.uppercase)
        XCTAssertEqual(TextStyleEdits.resetHelp(preset: "Label", value: "on"), "This clip's own. Click for the Label preset's: on.")
        XCTAssertEqual(TextStyleEdits.resetHelp(preset: nil, value: "64 pt"), "This clip's own. Click for the default: 64 pt.")
    }
}
