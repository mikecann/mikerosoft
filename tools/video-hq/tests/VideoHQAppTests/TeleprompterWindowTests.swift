import AppKit
import XCTest
@testable import VideoHQApp

final class TeleprompterWindowTests: XCTestCase {
    func testTeleprompterUsesCompactCenteredReadingLayout() {
        XCTAssertEqual(TeleprompterLayout.paragraphSpacing, 44)
        XCTAssertEqual(TeleprompterLayout.spokenLineSpacing, 8)
        XCTAssertEqual(TeleprompterLayout.horizontalPadding, 160)
        XCTAssertEqual(TeleprompterLayout.explicitBlankHeight, 12)
    }

    func testParagraphNavigatorAdvancesOnlyThroughSpokenParagraphs() {
        let blocks: [TeleprompterScriptBlock] = [
            .callout("camera cue"),
            .spoken("First"),
            .code(language: "swift", text: "print(1)"),
            .spoken("Second"),
            .space,
            .spoken("Third"),
        ]

        XCTAssertEqual(TeleprompterParagraphNavigator.spokenIndices(in: blocks), [1, 3, 5])
        XCTAssertEqual(TeleprompterParagraphNavigator.nextIndex(after: nil, in: blocks), 1)
        XCTAssertEqual(TeleprompterParagraphNavigator.nextIndex(after: 1, in: blocks), 3)
        XCTAssertEqual(TeleprompterParagraphNavigator.nextIndex(after: 3, in: blocks), 5)
        XCTAssertEqual(TeleprompterParagraphNavigator.nextIndex(after: 5, in: blocks), 5)
    }


    func testTeleprompterUsesAStandardResizableWindow() {
        XCTAssertEqual(
            TeleprompterWindowPlacement.styleMask,
            [.titled, .closable, .miniaturizable, .resizable]
        )
        XCTAssertEqual(TeleprompterWindowPlacement.windowLevel, .normal)
    }

    func testParserSeparatesSpokenParagraphsAndGroupsProductionBlocks() {
        let script = """
        First spoken paragraph.
        Second spoken paragraph.
        ```typescript
        const answer = 42;
        ```
        <callout icon="💡" color="gray_bg">
            back to me
        </callout>
        Final spoken paragraph.
        """

        XCTAssertEqual(
            TeleprompterScriptParser.parse(script),
            [
                .spoken("First spoken paragraph."),
                .spoken("Second spoken paragraph."),
                .code(language: "typescript", text: "const answer = 42;"),
                .callout("back to me"),
                .spoken("Final spoken paragraph."),
            ]
        )
    }

    func testParserTreatsEmptyBlocksAsExtraParagraphSpace() {
        XCTAssertEqual(
            TeleprompterScriptParser.parse("Before\n<empty-block/>\nAfter"),
            [.spoken("Before"), .space, .spoken("After")]
        )
    }

    func testParserOnlyIncludesTheScriptSection() {
        let document = """
        # Video title
        # Notes
        This should not appear.
        # Script
        First spoken paragraph.
        ## A section inside the script
        Second spoken paragraph.
        # Links
        This should not appear either.
        """

        XCTAssertEqual(
            TeleprompterScriptParser.parse(document),
            [
                .spoken("First spoken paragraph."),
                .spoken("## A section inside the script"),
                .spoken("Second spoken paragraph."),
            ]
        )
    }

    func testParserFallsBackToWholeDocumentWithoutAScriptHeading() {
        XCTAssertEqual(
            TeleprompterScriptParser.parse("A plain script.\nAnother paragraph."),
            [.spoken("A plain script."), .spoken("Another paragraph.")]
        )
    }

    func testRecognizesElgatoPrompterDisplayName() {
        XCTAssertTrue(TeleprompterWindowPlacement.isPrompterDisplay(named: "Elgato Prom."))
        XCTAssertTrue(TeleprompterWindowPlacement.isPrompterDisplay(named: "Elgato Prompter"))
        XCTAssertFalse(TeleprompterWindowPlacement.isPrompterDisplay(named: "LG Monitor"))
    }

    func testWindowReservesSpaceForTheMikerosoftTaskbar() {
        let screen = CGRect(x: -2944, y: 571, width: 1024, height: 600)

        let frame = TeleprompterWindowPlacement.windowFrame(in: screen)

        XCTAssertEqual(frame, CGRect(x: -2944, y: 603, width: 1024, height: 568))
    }

    func testWindowStillFitsASmallerDisplay() {
        let screen = CGRect(x: 100, y: 200, width: 640, height: 400)

        let frame = TeleprompterWindowPlacement.windowFrame(in: screen)

        XCTAssertEqual(frame, CGRect(x: 100, y: 232, width: 640, height: 368))
    }
}
