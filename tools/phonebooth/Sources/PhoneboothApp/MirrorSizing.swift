import CoreGraphics

/// Window sizing for a phone's screen. Pure so the maths is testable.
enum MirrorSizing {
    /// Longest edge a new window gets, so a phone doesn't open full height on a 4K display.
    static let maxInitialLongEdge: CGFloat = 900
    /// Used until the phone reports its screen size.
    static let placeholderSize = CGSize(width: 360, height: 780)

    /// Size for a phone's first window: as large as fits comfortably on the screen.
    static func initialContentSize(for video: CGSize, visibleFrame: CGRect) -> CGSize {
        guard video.width > 0, video.height > 0 else { return placeholderSize }
        let box = CGSize(width: visibleFrame.width * 0.9, height: visibleFrame.height * 0.85)
        let fit = min(box.width / video.width, box.height / video.height)
        let scale = min(fit, maxInitialLongEdge / max(video.width, video.height))
        return CGSize(width: (video.width * scale).rounded(), height: (video.height * scale).rounded())
    }

    /// Size after the phone rotates or changes resolution. The long edge stays put.
    static func contentSize(for video: CGSize, keepingLongEdgeOf current: CGSize) -> CGSize {
        guard video.width > 0, video.height > 0 else { return current }
        let scale = max(current.width, current.height) / max(video.width, video.height)
        return CGSize(width: (video.width * scale).rounded(), height: (video.height * scale).rounded())
    }

    /// Where the video sits inside a view that shows it aspect-fit.
    static func videoRect(in bounds: CGSize, video: CGSize) -> CGRect {
        guard video.width > 0, video.height > 0, bounds.width > 0, bounds.height > 0 else {
            return CGRect(origin: .zero, size: bounds)
        }
        let scale = min(bounds.width / video.width, bounds.height / video.height)
        let size = CGSize(width: video.width * scale, height: video.height * scale)
        return CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
    }

    /// A point in an unflipped view as a fraction of the phone's screen, origin top-left.
    /// Points outside the video return nil unless `clamped`, which pins them to the edge.
    static func fraction(of point: CGPoint, in bounds: CGSize, video: CGSize, clamped: Bool = false) -> CGPoint? {
        let rect = videoRect(in: bounds, video: video)
        guard rect.width > 0, rect.height > 0 else { return nil }
        var x = (point.x - rect.minX) / rect.width
        var y = (rect.maxY - point.y) / rect.height
        if clamped {
            x = min(max(x, 0), 1)
            y = min(max(y, 0), 1)
        }
        guard (0...1).contains(x), (0...1).contains(y) else { return nil }
        return CGPoint(x: x, y: y)
    }

    /// Resizes a window frame while keeping its top-left corner where it was.
    static func frame(_ frame: CGRect, resizedTo size: CGSize) -> CGRect {
        CGRect(x: frame.minX, y: frame.maxY - size.height, width: size.width, height: size.height)
    }
}
