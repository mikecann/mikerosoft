import XCTest
@testable import TandemAPI
@testable import TandemCore

/// Keeps docs/AGENTS.md honest: every edit command is documented with an
/// example, and every JSON example in the guide decodes.
final class DocsTests: XCTestCase {
    static let guide = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("docs/AGENTS.md")

    func text() throws -> String {
        try String(contentsOf: Self.guide, encoding: .utf8)
    }

    /// The contents of every ```json block after `start`.
    func jsonBlocks(in text: Substring) -> [String] {
        var blocks: [String] = []
        var rest = text
        while let open = rest.range(of: "```json\n") {
            guard let close = rest.range(of: "\n```", range: open.upperBound..<rest.endIndex) else { break }
            blocks.append(String(rest[open.upperBound..<close.lowerBound]))
            rest = rest[close.upperBound...]
        }
        return blocks
    }

    func testEveryCommandHasASectionWithAWorkingExample() throws {
        let text = try text()
        let start = try XCTUnwrap(text.range(of: "## Edit command reference"))
        let end = try XCTUnwrap(text.range(of: "## Recipes"))
        let reference = text[start.upperBound..<end.lowerBound]
        for command in CommandCase.allCases {
            let heading = "#### \(command.rawValue)\n"
            guard let found = reference.range(of: heading) else {
                XCTFail("docs/AGENTS.md has no section for \(command.rawValue)")
                continue
            }
            let block = try XCTUnwrap(jsonBlocks(in: reference[found.upperBound...]).first, "\(command.rawValue) has no example")
            let decoded = try CommandJSON.decode(try json(block), path: command.rawValue)
            XCTAssertEqual(decoded.commandCase, command, "the example under \(command.rawValue) is a different command")
        }
    }

    func testEveryJSONExampleInTheGuideDecodes() throws {
        let text = try text()
        let blocks = jsonBlocks(in: text[...])
        XCTAssertGreaterThan(blocks.count, CommandCase.allCases.count)
        for block in blocks {
            let value = try json(block)
            switch value {
            case .object(let fields) where fields["commands"] != nil:
                XCTAssertNoThrow(try ServiceJSON.decodeRequest(ApplyRequest.self, from: Data(block.utf8)), block)
            case .object(let fields) where fields.count == 1 && CommandCase(rawValue: fields.keys.first!) != nil:
                XCTAssertNoThrow(try CommandJSON.decode(value), block)
            default:
                XCTFail("unexpected JSON example in the guide: \(block)")
            }
        }
    }

    func testTheGuideHasNoLongDashes() throws {
        XCTAssertFalse(try text().contains("\u{2014}"), "no em dashes")
    }
}
