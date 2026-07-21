import Foundation
import XCTest
@testable import VideoHQApp

final class MarkdownPreviewTests: XCTestCase {
    func testRendererRemovesMarkdownMarkersAndKeepsSemanticFormatting() {
        let rendered = MarkdownPreviewRenderer.render("""
        # Heading

        **Bold** and `code`

        - One
        - Two
        """)

        XCTAssertEqual(String(rendered.characters), "HeadingBold and codeOneTwo")
        XCTAssertTrue(rendered.runs.contains { $0.presentationIntent != nil })
        XCTAssertTrue(rendered.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
        XCTAssertTrue(rendered.runs.contains { $0.inlinePresentationIntent?.contains(.code) == true })
    }

    func testRendererKeepsMalformedMarkdownReadable() {
        let rendered = MarkdownPreviewRenderer.render("Opening [unfinished link")

        XCTAssertEqual(String(rendered.characters), "Opening [unfinished link")
    }

    func testRendererSeparatesMarkdownIntoPresentableBlocks() {
        let blocks = MarkdownPreviewRenderer.blocks(from: """
        # Heading

        Paragraph.

        - One
        - Two

        > Quote

        ```swift
        let answer = 42
        ```
        """)

        XCTAssertEqual(
            blocks.map(\.kind),
            [
                .heading(level: 1),
                .paragraph,
                .unorderedListItem,
                .unorderedListItem,
                .blockQuote,
                .codeBlock(language: "swift"),
            ]
        )
        XCTAssertEqual(blocks.map { String($0.content.characters) }, [
            "Heading",
            "Paragraph.",
            "One",
            "Two",
            "Quote",
            "let answer = 42\n",
        ])
    }

    func testPreviewOmitsNotionEmptyBlockMarkers() {
        let blocks = MarkdownPreviewRenderer.blocks(from: """
        # Script
        <empty-block/>
        Opening line.
        """)

        XCTAssertEqual(blocks.map { String($0.content.characters) }, ["Script", "Opening line."])
    }
}
