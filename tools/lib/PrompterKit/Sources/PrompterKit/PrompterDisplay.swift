import AppKit

public enum PrompterDisplay {
    // Mike's taskbar is 31.7 points tall. Reserve a rounded 32-point strip so
    // its reveal area never overlaps a prompter window.
    public static let taskbarReservation: CGFloat = 32

    public static func isPrompterDisplay(named name: String) -> Bool {
        // macOS and DisplayLink sometimes shorten the display name to
        // "Elgato Prom.", so match the stable product-name stem.
        let normalized = name.lowercased()
        return normalized.contains("elgato") && normalized.contains("prom")
    }

    /// The Elgato Prompter screen, if it is connected and switched on.
    @MainActor
    public static func prompterScreen() -> NSScreen? {
        NSScreen.screens.first { isPrompterDisplay(named: $0.localizedName) }
    }

    /// Fills a screen's visible frame, leaving room for the taskbar.
    public static func fillFrame(in visibleFrame: CGRect) -> CGRect {
        let reservation = min(taskbarReservation, max(0, visibleFrame.height - 240))
        return CGRect(
            x: visibleFrame.minX,
            y: visibleFrame.minY + reservation,
            width: visibleFrame.width,
            height: visibleFrame.height - reservation
        )
    }
}
