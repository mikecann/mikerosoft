import AppKit
import XCTest
@testable import TandemApp

final class KeyChordTests: XCTestCase {
    func testParsingAndCanonicalSpelling() {
        XCTAssertEqual(KeyChord("Shift+Cmd+Z")?.description, "cmd+shift+z")
        XCTAssertEqual(KeyChord("cmd+shift+z"), KeyChord(key: "z", modifiers: [.command, .shift]))
        XCTAssertEqual(KeyChord("shift+,"), KeyChord(key: ",", modifiers: [.shift]))
        XCTAssertEqual(KeyChord("'"), KeyChord(key: "'"))
        XCTAssertEqual(KeyChord("space"), KeyChord(key: "space"))
        XCTAssertEqual(KeyChord("backspace"), KeyChord(key: "delete"))
        XCTAssertEqual(KeyChord("cmd++"), KeyChord(key: "+", modifiers: [.command]))
        XCTAssertEqual(KeyChord("alt+x"), KeyChord(key: "x", modifiers: [.option]))
        XCTAssertNil(KeyChord("hyper+x"))
        XCTAssertNil(KeyChord("cmd+banana"))
        XCTAssertNil(KeyChord(""))
    }

    func testMenuSymbols() {
        XCTAssertEqual(KeyChord("cmd+shift+z")?.symbol, "⇧⌘Z")
        XCTAssertEqual(KeyChord("shift+delete")?.symbol, "⇧⌫")
        XCTAssertEqual(KeyChord("space")?.symbol, "Space")
    }
}

final class KeymapTests: XCTestCase {
    /// The keymap that ships with the app, read from the source tree.
    static func bundledKeymapData() throws -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/TandemApp/Resources/Keymaps/premiere.json")
        return try Data(contentsOf: url)
    }

    func testTheBundledKeymapCoversTheBrief() throws {
        let keymap = try Keymap.load(Self.bundledKeymapData())
        let expected: [String: EditorCommand] = [
            "space": .playPause, "j": .shuttleReverse, "k": .shuttleStop, "l": .shuttleForward,
            "i": .markIn, "o": .markOut, ";": .liftInOut, "'": .extractInOut,
            "cmd+b": .bladeAtPlayhead, "q": .rippleTrimStart, "w": .rippleTrimEnd,
            "delete": .lift, "shift+delete": .rippleDelete, "a": .selectForward,
            "up": .previousEdit, "down": .nextEdit, ",": .nudgeLeft, ".": .nudgeRight,
            "shift+,": .nudgeLeftFive, "shift+.": .nudgeRightFive, "shift+z": .zoomToFit,
            "cmd+=": .zoomIn, "cmd+-": .zoomOut, "s": .toggleSnapping, "cmd+l": .link, "m": .addMarker,
            "cmd+z": .undo, "cmd+shift+z": .redo, "cmd+s": .save, "cmd+e": .export,
            "1": .layoutFull, "2": .layoutPipRight, "3": .layoutPipLeft, "4": .layoutSplit,
            "option+k": .toggleKeyframe, "shift+j": .previousKeyframe, "shift+k": .nextKeyframe,
            "cmd+option+v": .addVideoTrack, "cmd+option+a": .addAudioTrack
        ]
        for (text, command) in expected {
            XCTAssertEqual(keymap.command(for: KeyChord(text)!), command, text)
        }
    }

    func testEveryTransportAndEditingCommandHasAKey() throws {
        let keymap = try Keymap.load(Self.bundledKeymapData())
        let unbound = EditorCommand.allCases.filter { keymap.chords(for: $0).isEmpty }
        XCTAssertEqual(unbound, [], "commands without a key in the default keymap")
    }

    func testProblemsAreReportedTogether() {
        let data = Data(#"{"bindings": {"cmd+q+x": "undo", "z": "flyToTheMoon", "x": "undo"}}"#.utf8)
        XCTAssertThrowsError(try Keymap.load(data)) { error in
            guard case KeymapError.invalid(let problems) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(problems.count, 2)
            XCTAssertTrue(problems.contains { $0.contains("flyToTheMoon") })
        }
    }

    func testDifferentSpellingsOfOneKeyClash() {
        let data = Data(#"{"bindings": {"cmd+shift+z": "redo", "shift+cmd+z": "undo"}}"#.utf8)
        XCTAssertThrowsError(try Keymap.load(data))
    }

    func testUserKeymapMergesOverTheDefaults() throws {
        let defaults = try Keymap.load(Self.bundledKeymapData())
        let user = try Keymap.parse(Data(#"{"name": "Mine", "bindings": {"m": null, "f": "addMarker", "k": "playPause"}}"#.utf8))
        let merged = defaults.merged(with: user.keymap, removing: user.removals)
        XCTAssertNil(merged.command(for: KeyChord("m")!))
        XCTAssertEqual(merged.command(for: KeyChord("f")!), .addMarker)
        XCTAssertEqual(merged.command(for: KeyChord("k")!), .playPause)
        XCTAssertEqual(merged.command(for: KeyChord("space")!), .playPause, "untouched defaults stay")
    }

    func testMenusPreferACommandShortcut() throws {
        let keymap = try Keymap.load(Self.bundledKeymapData())
        XCTAssertEqual(keymap.menuChord(for: .zoomIn), KeyChord("cmd+="))
        XCTAssertEqual(keymap.menuChord(for: .bladeAtPlayhead), KeyChord("cmd+b"))
        XCTAssertEqual(keymap.menuChord(for: .addMarker), KeyChord("m"))
        XCTAssertEqual(keymap.chords(for: .lift).first, KeyChord("delete"))
    }
}

@MainActor
final class KeyboardRouterTests: XCTestCase {
    func event(_ characters: String, keyCode: UInt16, flags: NSEvent.ModifierFlags = [], type: NSEvent.EventType = .keyDown) -> NSEvent {
        NSEvent.keyEvent(
            with: type, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
            characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode
        )!
    }

    func testChordsFromKeyEvents() {
        XCTAssertEqual(KeyChord(event: event(" ", keyCode: 49)), KeyChord("space"))
        XCTAssertEqual(KeyChord(event: event("\u{7F}", keyCode: 51, flags: [.shift])), KeyChord("shift+delete"))
        XCTAssertEqual(KeyChord(event: event("\u{F702}", keyCode: 123, flags: [.option, .numericPad, .function])), KeyChord("option+left"))
        XCTAssertEqual(KeyChord(event: event("b", keyCode: 11, flags: [.command])), KeyChord("cmd+b"))
    }

    func testRoutesCommandsAndSteppingWithKHeld() throws {
        let router = KeyboardRouter(keymap: try Keymap.load(KeymapTests.bundledKeymapData()))
        var performed: [EditorCommand] = []
        var steps: [Int64] = []
        var held: [(String, Bool)] = []
        router.perform = { performed.append($0); return true }
        router.step = { steps.append($0) }
        router.holdChanged = { held.append(($0, $1)) }

        XCTAssertTrue(router.route(KeyChord("l")!, keyUp: false, isRepeat: false))
        XCTAssertTrue(router.route(KeyChord("k")!, keyUp: false, isRepeat: false))
        XCTAssertTrue(router.route(KeyChord("l")!, keyUp: false, isRepeat: false), "K held: L steps a frame")
        XCTAssertTrue(router.route(KeyChord("j")!, keyUp: false, isRepeat: false))
        _ = router.route(KeyChord("k")!, keyUp: true, isRepeat: false)
        XCTAssertTrue(router.route(KeyChord("j")!, keyUp: false, isRepeat: false))
        XCTAssertEqual(performed, [.shuttleForward, .shuttleStop, .shuttleReverse])
        XCTAssertEqual(steps, [1, -1])

        XCTAssertTrue(router.route(KeyChord(",")!, keyUp: false, isRepeat: true), "nudges repeat")
        XCTAssertTrue(router.route(KeyChord("m")!, keyUp: false, isRepeat: true), "held M doesn't add a marker per repeat")
        XCTAssertEqual(performed.suffix(1), [.nudgeLeft])
        XCTAssertFalse(router.route(KeyChord("cmd+ctrl+9")!, keyUp: false, isRepeat: false), "unbound keys pass through")

        XCTAssertTrue(router.route(KeyChord("z")!, keyUp: false, isRepeat: false))
        _ = router.route(KeyChord("z")!, keyUp: true, isRepeat: false)
        XCTAssertEqual(held.map(\.1), [true, false])

        // Shift-K is the next keyframe, not K held, and it repeats.
        steps = []
        XCTAssertTrue(router.route(KeyChord("shift+k")!, keyUp: false, isRepeat: false))
        XCTAssertTrue(router.route(KeyChord("shift+k")!, keyUp: false, isRepeat: true))
        XCTAssertTrue(router.route(KeyChord("option+k")!, keyUp: false, isRepeat: false))
        XCTAssertTrue(router.route(KeyChord("option+k")!, keyUp: false, isRepeat: true), "one keyframe per press")
        XCTAssertEqual(performed.suffix(3), [.nextKeyframe, .nextKeyframe, .toggleKeyframe])
        XCTAssertTrue(steps.isEmpty)
    }
}
