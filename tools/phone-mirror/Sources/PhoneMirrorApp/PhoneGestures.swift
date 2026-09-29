import CoreGraphics
import Foundation

/// A mouse position over the phone, as a fraction of its width and height (origin top-left).
struct TouchSample: Equatable {
    var point: CGPoint
    var time: TimeInterval
}

/// A point on the phone in its own points, with its time since the gesture began.
struct TimedPoint: Equatable {
    var point: CGPoint
    var time: TimeInterval
}

enum PhoneGesture: Equatable {
    case tap(CGPoint)
    case longPress(CGPoint, duration: TimeInterval)
    case drag([TimedPoint])
}

/// Turns what the mouse did between press and release into a phone gesture.
enum GestureClassifier {
    /// How far the mouse can wander (in phone points) and still count as a tap.
    static let tapSlop: CGFloat = 10
    static let longPressDuration: TimeInterval = 0.5
    static let minimumSampleInterval: TimeInterval = 0.016

    static func gesture(from samples: [TouchSample], screen: CGSize) -> PhoneGesture? {
        guard let first = samples.first, let last = samples.last, screen.width > 0, screen.height > 0 else { return nil }
        let path = samples.map {
            TimedPoint(point: phonePoint($0.point, on: screen), time: milliseconds($0.time - first.time))
        }
        let start = path[0].point
        let moved = path.contains { hypot($0.point.x - start.x, $0.point.y - start.y) > tapSlop }
        guard moved else {
            let duration = milliseconds(last.time - first.time)
            return duration >= longPressDuration ? .longPress(start, duration: duration) : .tap(start)
        }
        return .drag(thinned(path))
    }

    static func phonePoint(_ fraction: CGPoint, on screen: CGSize) -> CGPoint {
        CGPoint(
            x: (min(max(fraction.x, 0), 1) * screen.width).rounded(),
            y: (min(max(fraction.y, 0), 1) * screen.height).rounded()
        )
    }

    /// Keeps at most one sample per frame so a long drag still fits in one request.
    private static func thinned(_ path: [TimedPoint]) -> [TimedPoint] {
        guard var kept = path.first.map({ [$0] }) else { return [] }
        for point in path.dropFirst().dropLast() where point.time - kept[kept.count - 1].time >= minimumSampleInterval - 0.0001 {
            kept.append(point)
        }
        if let last = path.last, path.count > 1 {
            if last.time - kept[kept.count - 1].time < minimumSampleInterval - 0.0001, kept.count > 1 {
                kept.removeLast()
            }
            kept.append(last)
        }
        return kept
    }

    private static func milliseconds(_ interval: TimeInterval) -> TimeInterval {
        (interval * 1000).rounded() / 1000
    }
}

/// W3C WebDriver pointer actions, which WebDriverAgent replays as a real touch.
enum TouchActions {
    static func drag(_ path: [TimedPoint], holdAtEnd: TimeInterval = 0) -> [String: Any] {
        guard let start = path.first else { return ["actions": []] }
        var steps: [[String: Any]] = [
            move(to: start.point, duration: 0),
            ["type": "pointerDown", "button": 0],
        ]
        for (previous, next) in zip(path, path.dropFirst()) {
            steps.append(move(to: next.point, duration: next.time - previous.time))
        }
        if holdAtEnd > 0 {
            steps.append(["type": "pause", "duration": Int((holdAtEnd * 1000).rounded())])
        }
        steps.append(["type": "pointerUp", "button": 0])
        return ["actions": [[
            "type": "pointer",
            "id": "finger",
            "parameters": ["pointerType": "touch"],
            "actions": steps,
        ] as [String: Any]]]
    }

    private static func move(to point: CGPoint, duration: TimeInterval) -> [String: Any] {
        ["type": "pointerMove", "duration": Int((duration * 1000).rounded()), "x": Int(point.x), "y": Int(point.y)]
    }
}

/// Scroll wheel and trackpad input becomes a finger drag. Scroll deltas describe which way the
/// content moves, and a finger drags content the same way, so the delta is the finger's movement.
enum ScrollSwipe {
    static let margin: CGFloat = 40
    static let duration: TimeInterval = 0.15

    static func path(anchor: CGPoint, delta: CGVector, screen: CGSize) -> [TimedPoint] {
        let x = axis(anchor.x, delta.dx, length: screen.width)
        let y = axis(anchor.y, delta.dy, length: screen.height)
        return [
            TimedPoint(point: CGPoint(x: x.start, y: y.start), time: 0),
            TimedPoint(point: CGPoint(x: x.end, y: y.end), time: duration),
        ]
    }

    /// Start and end along one axis, both kept inside the margins.
    private static func axis(_ anchor: CGFloat, _ delta: CGFloat, length: CGFloat) -> (start: CGFloat, end: CGFloat) {
        let low = margin, high = length - margin
        let travel = max(-(high - low), min(high - low, delta.rounded()))
        var start = min(max(anchor.rounded(), low), high)
        if start + travel < low { start = low - travel }
        if start + travel > high { start = high - travel }
        return (start, start + travel)
    }
}

/// What to type on the phone for a Mac key press. Special keys use the strings XCTest expects.
enum PhoneKeys {
    private static let special: [UInt16: String] = [
        0x33: "\u{8}",     // Delete (backspace)
        0x75: "\u{7F}",    // Forward delete
        0x24: "\n",        // Return
        0x4C: "\n",        // Keypad enter
        0x30: "\t",        // Tab
        0x35: "\u{1B}",    // Escape
        0x7E: "\u{F700}",  // Up
        0x7D: "\u{F701}",  // Down
        0x7B: "\u{F702}",  // Left
        0x7C: "\u{F703}",  // Right
    ]

    static func text(keyCode: UInt16, characters: String?) -> String? {
        if let key = special[keyCode] { return key }
        guard let characters, !characters.isEmpty else { return nil }
        let typeable = characters.unicodeScalars.allSatisfy { scalar in
            scalar.value >= 0x20 && scalar.value != 0x7F && !(0xF700...0xF8FF).contains(scalar.value)
        }
        return typeable ? characters : nil
    }
}
