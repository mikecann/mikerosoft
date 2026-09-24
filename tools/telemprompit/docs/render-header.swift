// Renders docs/header.png. Run from tools/telemprompit: swift docs/render-header.swift docs/header.png
import AppKit
let W: CGFloat = 1200, H: CGFloat = 500
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W), pixelsHigh: Int(H), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let bg = NSGradient(colors: [NSColor(srgbRed: 0.42, green: 0.30, blue: 0.05, alpha: 1), NSColor(srgbRed: 0.13, green: 0.12, blue: 0.10, alpha: 1), NSColor(srgbRed: 0.05, green: 0.05, blue: 0.06, alpha: 1)], atLocations: [0, 0.5, 1], colorSpace: .sRGB)!
bg.draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: 0)
let icon = NSImage(contentsOfFile: "icons/telemprompit.png")!
icon.draw(in: NSRect(x: 100, y: 130, width: 240, height: 240))
func font(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
    let base = NSFont.systemFont(ofSize: size, weight: weight)
    return NSFont(descriptor: base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor, size: size) ?? base
}
("Telemprompit" as NSString).draw(at: NSPoint(x: 400, y: 255), withAttributes: [.font: font(84, .semibold), .foregroundColor: NSColor.white])
("Your notes on the Elgato Prompter, one line at a time" as NSString).draw(at: NSPoint(x: 404, y: 210), withAttributes: [.font: font(28, .regular), .foregroundColor: NSColor.white.withAlphaComponent(0.85)])
var x: CGFloat = 404
for chip in ["PASTE NOTES", "CLICK TO ADVANCE", "AUTO-SCROLL", "MIRROR"] {
    let attrs: [NSAttributedString.Key: Any] = [.font: font(20, .medium), .foregroundColor: NSColor.white.withAlphaComponent(0.9)]
    let size = (chip as NSString).size(withAttributes: attrs)
    let rect = NSRect(x: x, y: 130, width: size.width + 36, height: 46)
    let path = NSBezierPath(roundedRect: rect, xRadius: 23, yRadius: 23)
    NSColor.white.withAlphaComponent(0.08).setFill(); path.fill()
    NSColor.white.withAlphaComponent(0.35).setStroke(); path.lineWidth = 1.5; path.stroke()
    (chip as NSString).draw(at: NSPoint(x: rect.minX + 18, y: rect.minY + (46 - size.height) / 2), withAttributes: attrs)
    x = rect.maxX + 14
}
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
