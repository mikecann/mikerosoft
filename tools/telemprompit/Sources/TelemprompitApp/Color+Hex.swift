import AppKit
import SwiftUI

extension Color {
    init(hex: String, fallback: Color = .white) {
        guard let rgb = HexColor.components(hex) else { self = fallback; return }
        self.init(.sRGB, red: rgb[0], green: rgb[1], blue: rgb[2])
    }

    var hexString: String {
        let color = NSColor(self).usingColorSpace(.sRGB) ?? .white
        return HexColor.string(
            red: Double(color.redComponent),
            green: Double(color.greenComponent),
            blue: Double(color.blueComponent)
        )
    }
}
