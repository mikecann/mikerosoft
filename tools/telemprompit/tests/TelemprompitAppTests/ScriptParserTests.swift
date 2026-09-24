import XCTest
@testable import TelemprompitApp

final class ScriptParserTests: XCTestCase {
    func testPlainParagraphsBecomeLinesAndBlankLinesAreDropped() {
        XCTAssertEqual(
            ScriptParser.parse("Hello there.\n\n\nSecond thought.\r\nThird"),
            [.line("Hello there."), .line("Second thought."), .line("Third")]
        )
    }

    func testStripsBulletMarkersAndKeepsNestingDepth() {
        let notes = """
        - Intro
            - Who I am
                - Convex DevRel
            - What we're building
        * Star bullet
        + Plus bullet
        • Unicode bullet
        """
        XCTAssertEqual(ScriptParser.parse(notes), [
            .line("Intro"),
            .line("Who I am", depth: 1),
            .line("Convex DevRel", depth: 2),
            .line("What we're building", depth: 1),
            .line("Star bullet"),
            .line("Plus bullet"),
            .line("Unicode bullet"),
        ])
    }

    func testTwoSpaceAndTabIndentsBothMeanOneLevel() {
        XCTAssertEqual(
            ScriptParser.parse("- a\n  - b\n    - c\n\t- d\n\t\t- e"),
            [.line("a"), .line("b", depth: 1), .line("c", depth: 2), .line("d", depth: 1), .line("e", depth: 2)]
        )
    }

    func testIndentationIsRelativeToTheLeastIndentedLine() {
        // Text copied from the middle of a nested list keeps its leading indent.
        XCTAssertEqual(
            ScriptParser.parse("    - a\n        - b"),
            [.line("a"), .line("b", depth: 1)]
        )
    }

    func testStripsNumberedListsAndCheckboxes() {
        XCTAssertEqual(
            ScriptParser.parse("1. First\n2) Second\n- [ ] Todo\n- [x] Done"),
            [.line("First"), .line("Second"), .line("Todo"), .line("Done")]
        )
    }

    func testKeepsNumbersThatAreNotListMarkers() {
        XCTAssertEqual(ScriptParser.parse("2024 was a big year."), [.line("2024 was a big year.")])
    }

    func testRemovesInlineMarkdownButKeepsTheWords() {
        XCTAssertEqual(
            ScriptParser.parse("- **Bold** and *italic*, __under__ ~~gone~~ `code` [a link](https://x.dev) snake_case_name"),
            [.line("Bold and italic, under gone code a link snake_case_name")]
        )
    }

    func testHeadingsBecomeSectionMarkersWithoutNotionAttributes() {
        XCTAssertEqual(
            ScriptParser.parse("# Script {toggle=\"true\"}\n## Part two\n- line"),
            [.heading("Script"), .heading("Part two"), .line("line")]
        )
    }

    func testNotionCalloutsBecomeCuesAndLayoutTagsDisappear() {
        let notes = """
        Say this.
        <callout icon="💡" color="gray_bg">
            back to me
        </callout>
        <empty-block/>
        ---
        Then this.
        """
        XCTAssertEqual(
            ScriptParser.parse(notes),
            [.line("Say this."), .cue("back to me"), .line("Then this.")]
        )
    }

    func testFencedCodeBecomesASingleCodeBlock() {
        let notes = """
        - Show the query
        ```ts
        const x = 1;
        const y = 2;
        ```
        - Explain it
        """
        XCTAssertEqual(ScriptParser.parse(notes), [
            .line("Show the query"),
            PromptItem(kind: .code, text: "const x = 1;\nconst y = 2;"),
            .line("Explain it"),
        ])
    }

    func testBlockquotesAndBareBulletsAreHandled() {
        XCTAssertEqual(ScriptParser.parse("> quoted\n-\n- real"), [.line("quoted"), .line("real")])
    }

    func testDecodesCommonHTMLEntitiesFromNotionExports() {
        XCTAssertEqual(ScriptParser.parse("Tom &amp; Jerry&nbsp;&lt;3"), [.line("Tom & Jerry <3")])
    }
}
