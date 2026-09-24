import AppKit
import PrompterKit

/// Picks the screen and frame the prompter window opens with.
enum WindowPlacement {
    struct Screen: Equatable {
        var name: String
        var visibleFrame: CGRect
    }

    static let fallbackSize = CGSize(width: 960, height: 560)

    /// The Elgato Prompter when it is on, otherwise the menu-bar screen.
    static func targetScreen(in screens: [Screen]) -> Screen? {
        screens.first { PrompterDisplay.isPrompterDisplay(named: $0.name) } ?? screens.first
    }

    static func frame(on screen: Screen, saved: [String: CGRect]) -> CGRect {
        if let frame = saved[screen.name], mostlyVisible(frame, on: screen.visibleFrame) {
            return frame
        }
        if PrompterDisplay.isPrompterDisplay(named: screen.name) {
            return PrompterDisplay.fillFrame(in: screen.visibleFrame)
        }
        let visible = screen.visibleFrame
        let size = CGSize(
            width: min(fallbackSize.width, visible.width),
            height: min(fallbackSize.height, visible.height)
        )
        return CGRect(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    private static func mostlyVisible(_ frame: CGRect, on visible: CGRect) -> Bool {
        let overlap = frame.intersection(visible)
        guard !overlap.isNull, frame.width > 0, frame.height > 0 else { return false }
        return overlap.width * overlap.height >= frame.width * frame.height / 2
    }

    @MainActor
    static func screens() -> [Screen] {
        NSScreen.screens.map { Screen(name: $0.localizedName, visibleFrame: $0.visibleFrame) }
    }

    // MARK: - Remembered frames, one per display name

    private static let savedFramesKey = "windowFrames.v1"

    static func savedFrames(in defaults: UserDefaults = .standard) -> [String: CGRect] {
        let raw = defaults.dictionary(forKey: savedFramesKey) as? [String: [Double]] ?? [:]
        return raw.compactMapValues { values in
            values.count == 4 ? CGRect(x: values[0], y: values[1], width: values[2], height: values[3]) : nil
        }
    }

    static func save(_ frame: CGRect, for screenName: String, in defaults: UserDefaults = .standard) {
        var raw = defaults.dictionary(forKey: savedFramesKey) as? [String: [Double]] ?? [:]
        raw[screenName] = [frame.minX, frame.minY, frame.width, frame.height].map(Double.init)
        defaults.set(raw, forKey: savedFramesKey)
    }
}
