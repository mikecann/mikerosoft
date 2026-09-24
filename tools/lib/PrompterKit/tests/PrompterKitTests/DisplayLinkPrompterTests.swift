import XCTest
@testable import PrompterKit

final class DisplayLinkPrompterTests: XCTestCase {
    func testFindsTheSwitchBelongingToTheElgatoPrompterDisplay() {
        let tree = DisplayLinkAccessibilityNode(
            role: "AXApplication",
            children: [
                DisplayLinkAccessibilityNode(
                    role: "AXGroup",
                    children: [
                        DisplayLinkAccessibilityNode(role: "AXStaticText", text: "Studio Display"),
                        DisplayLinkAccessibilityNode(role: "AXCheckBox", boolValue: true)
                    ]
                ),
                DisplayLinkAccessibilityNode(
                    role: "AXGroup",
                    children: [
                        DisplayLinkAccessibilityNode(role: "AXStaticText", text: "Elgato Prom."),
                        DisplayLinkAccessibilityNode(role: "AXCheckBox", boolValue: false)
                    ]
                )
            ]
        )

        XCTAssertEqual(displayLinkTeleprompterSwitchPath(in: tree), [1, 1])
    }

    func testFindsALabelledPrompterSwitchWithoutDependingOnItsRowShape() {
        let tree = DisplayLinkAccessibilityNode(
            role: "AXApplication",
            children: [
                DisplayLinkAccessibilityNode(
                    role: "AXSwitch",
                    text: "Enable Elgato Prompter",
                    boolValue: true
                )
            ]
        )

        XCTAssertEqual(displayLinkTeleprompterSwitchPath(in: tree), [0])
    }

    func testPrompterSwitchUsesItsPressActionOnlyWhenTheStateNeedsToChange() {
        XCTAssertEqual(displayLinkPrompterSwitchAction(current: true, target: false), .press)
        XCTAssertEqual(displayLinkPrompterSwitchAction(current: false, target: true), .press)
        XCTAssertEqual(displayLinkPrompterSwitchAction(current: true, target: true), .none)
        XCTAssertEqual(displayLinkPrompterSwitchAction(current: false, target: false), .none)
        XCTAssertEqual(displayLinkPrompterSwitchAction(current: nil, target: false), .press)
    }
}
