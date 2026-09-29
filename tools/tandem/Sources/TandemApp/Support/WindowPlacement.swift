import AppKit

/// Where project windows open: where the last one was, while that's still
/// on a screen.
///
/// AppKit's own frame saving didn't work here. A window controller clears
/// the name set on its window, so nothing was saved, and when it does save
/// it puts the window back on whichever screen is active at launch (scaled
/// to fit), not the one it was on. So a restart to install a build put
/// the editor back at the default size on the wrong screen.
enum WindowPlacement {
    static let key = "projectWindowFrame"
    /// How much of a title bar has to be on a screen to grab it.
    static let grabWidth: CGFloat = 120

    static func save(_ frame: NSRect, to store: UserDefaults = AppDefaults.store) {
        store.set(NSStringFromRect(frame.integral), forKey: key)
    }

    static func saved(in store: UserDefaults = AppDefaults.store) -> NSRect? {
        guard let text = store.string(forKey: key) else { return nil }
        let frame = NSRectFromString(text)
        return frame.width >= 100 && frame.height >= 100 ? frame : nil
    }

    /// True when enough of the title bar is on a screen to grab and at
    /// least half the window shows. `screens` are visible frames.
    static func isOnScreen(_ frame: NSRect, screens: [NSRect]) -> Bool {
        let titleBar = NSRect(x: frame.minX, y: frame.maxY - 32, width: frame.width, height: 32)
        guard screens.contains(where: { $0.intersection(titleBar).width >= min(grabWidth, frame.width) }) else { return false }
        let shown = screens.reduce(CGFloat(0)) { $0 + area($1.intersection(frame)) }
        return shown >= area(frame) / 2
    }

    /// The saved frame if it's still on a screen, stepped down and right
    /// past any window already sitting there.
    static func restored(screens: [NSRect], occupied: [NSRect], store: UserDefaults = AppDefaults.store) -> NSRect? {
        guard var frame = saved(in: store), isOnScreen(frame, screens: screens) else { return nil }
        while occupied.contains(where: { $0.origin == frame.origin }) {
            frame = frame.offsetBy(dx: 24, dy: -24)
        }
        return frame
    }

    private static func area(_ rect: NSRect) -> CGFloat {
        rect.isNull ? 0 : rect.width * rect.height
    }
}
