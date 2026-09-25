import Foundation

/// One-key layouts for a clip (keys 1 to 4 in the app, `applyLayout` for
/// agents). The values come from Mike's Filmora projects: in 2026 every PiP
/// was 50% scale around (0.87, 0.77) with the portrait cutout, and most had
/// Filmora's default drop shadow.
public enum LayoutPreset: String, Codable, CaseIterable, Sendable {
    /// Fills the frame.
    case full
    /// 50% with the cutout, bottom right.
    case pipRight
    /// 50% with the cutout, bottom left.
    case pipLeft
    /// Camera on the right half, everything else on the left half.
    case split

    public var name: String {
        switch self {
        case .full: return "Full"
        case .pipRight: return "PiP right"
        case .pipLeft: return "PiP left"
        case .split: return "Split"
        }
    }

    public static let pipScale = 0.5
    public static let pipRightPosition = Point(x: 0.87, y: 0.77)
    public static let pipLeftPosition = Point(x: 0.13, y: 0.77)

    /// Filmora's default drop shadow, which Mike never changed.
    public static func pipShadow(id: String) -> Effect {
        Effect(id: id, type: "dropShadow", params: [
            "distance": .number(4), "blur": .number(5), "opacity": .number(60)
        ])
    }

    /// The clip's video properties with this layout applied. Effects other
    /// than the PiP shadow are kept.
    public func apply(to video: VideoProperties?, role: MediaRole?, shadowID: String) -> VideoProperties {
        var v = video ?? VideoProperties()
        v.layoutPreset = rawValue
        v.transform.rotation = 0
        let hasShadow = v.effects.contains { $0.type == "dropShadow" }
        switch self {
        case .full:
            v.transform = Transform()
            v.crop = Crop()
            if v.cutout != nil { v.cutout?.enabled = false }
            v.effects.removeAll { $0.type == "dropShadow" }
        case .pipRight, .pipLeft:
            v.transform.scale = Self.pipScale
            v.transform.position = self == .pipRight ? Self.pipRightPosition : Self.pipLeftPosition
            v.crop = Crop()
            var cutout = v.cutout ?? Cutout()
            cutout.enabled = true
            v.cutout = cutout
            if !hasShadow { v.effects.append(Self.pipShadow(id: shadowID)) }
        case .split:
            // Full height, the middle half of the frame, on one side.
            v.transform = Transform(position: Point(x: role == .camera ? 0.75 : 0.25, y: 0.5), scale: 1)
            v.crop = Crop(left: 0.25, top: 0, right: 0.25, bottom: 0)
            if v.cutout != nil { v.cutout?.enabled = false }
            v.effects.removeAll { $0.type == "dropShadow" }
        }
        return v
    }
}

extension Transform {
    /// The transform that fills the canvas with `rect` of the source (in
    /// source units, 0...1 from the top left), for zooming into part of a
    /// screen recording. Scale is never below 1, so zooming out past the
    /// full frame isn't possible.
    public static func showing(_ rect: Rect, sourceWidth: Double, sourceHeight: Double, canvasWidth: Double, canvasHeight: Double) -> Transform {
        let fit = min(canvasWidth / sourceWidth, canvasHeight / sourceHeight)
        let fittedWidth = sourceWidth * fit
        let fittedHeight = sourceHeight * fit
        let scale = max(1, min(canvasWidth / (rect.width * fittedWidth), canvasHeight / (rect.height * fittedHeight)))
        let centreX = rect.x + rect.width / 2
        let centreY = rect.y + rect.height / 2
        // Move the source so the rectangle's centre lands on the canvas
        // centre, without showing past the source's edges.
        var x = 0.5 - (centreX - 0.5) * fittedWidth * scale / canvasWidth
        var y = 0.5 - (centreY - 0.5) * fittedHeight * scale / canvasHeight
        let halfWidth = fittedWidth * scale / canvasWidth / 2
        let halfHeight = fittedHeight * scale / canvasHeight / 2
        if halfWidth >= 0.5 { x = min(max(x, 1 - halfWidth), halfWidth) }
        if halfHeight >= 0.5 { y = min(max(y, 1 - halfHeight), halfHeight) }
        return Transform(position: Point(x: x, y: y), scale: scale)
    }
}

/// Where a clip goes in a 9:16 short made from the landscape edit: Mike's
/// shorts put the screen in the top half and the camera in the bottom half,
/// with captions between, and full-frame camera moments fill the frame.
public enum PortraitSlot: String, Codable, CaseIterable, Sendable {
    case top, bottom, full

    /// The part of the canvas the slot covers: y from and to, 0 top to 1
    /// bottom, full width.
    var band: (top: Double, bottom: Double) {
        switch self {
        case .top: return (0, 0.5)
        case .bottom: return (0.5, 1)
        case .full: return (0, 1)
        }
    }
}

extension Transform {
    /// The transform that fills a full-width band of the canvas with the
    /// source, cropping its sides (cover, not fit).
    public static func filling(_ slot: PortraitSlot, sourceWidth: Double, sourceHeight: Double, canvasWidth: Double, canvasHeight: Double) -> Transform {
        let fit = min(canvasWidth / sourceWidth, canvasHeight / sourceHeight)
        let fittedWidth = sourceWidth * fit
        let fittedHeight = sourceHeight * fit
        let band = slot.band
        let bandHeight = (band.bottom - band.top) * canvasHeight
        let scale = max(canvasWidth / fittedWidth, bandHeight / fittedHeight)
        return Transform(position: Point(x: 0.5, y: (band.top + band.bottom) / 2), scale: scale)
    }
}
