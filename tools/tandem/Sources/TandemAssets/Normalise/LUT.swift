import CoreImage
import Foundation

/// 3D LUTs in the `.cube` format (Resolve, Premiere, most LUT packs).
/// The library keeps the file as it is; this reads it to check it and to
/// draw a before and after preview for the browser.
enum CubeLUT {
    struct Table {
        /// Points along each axis.
        var size: Int
        /// RGBA float32 values, red changing fastest, as Core Image wants.
        var data: Data
    }

    static func read(_ url: URL) throws -> Table {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw AssetError.normaliseFailed("can't read \(url.lastPathComponent) as text")
        }
        var size = 0
        var values: [Float] = []
        var domainMin: [Float] = [0, 0, 0]
        var domainMax: [Float] = [1, 1, 1]
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let first = line.first, first != "#" else { continue }
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if first.isNumber || first == "-" || first == "." {
                let numbers = fields.compactMap { Float($0) }
                if numbers.count == 3 { values += numbers + [1] }
                continue
            }
            let numbers = fields.dropFirst().compactMap { Float($0) }
            switch fields.first {
            case "LUT_3D_SIZE": size = Int(numbers.first ?? 0)
            case "DOMAIN_MIN" where numbers.count == 3: domainMin = numbers
            case "DOMAIN_MAX" where numbers.count == 3: domainMax = numbers
            case "LUT_1D_SIZE": throw AssetError.unsupported("\(url.lastPathComponent) is a 1D LUT; Tandem uses 3D LUTs")
            default: break
            }
        }
        guard size >= 2, size <= 256, values.count == size * size * size * 4 else {
            throw AssetError.normaliseFailed("\(url.lastPathComponent) isn't a complete 3D LUT (size \(size), \(values.count / 4) entries)")
        }
        // Core Image wants outputs in 0...1.
        if domainMin != [0, 0, 0] || domainMax != [1, 1, 1] {
            for index in stride(from: 0, to: values.count, by: 4) {
                for channel in 0..<3 {
                    values[index + channel] = (values[index + channel] - domainMin[channel]) / max(0.0001, domainMax[channel] - domainMin[channel])
                }
            }
        }
        return Table(size: size, data: values.withUnsafeBufferPointer { Data(buffer: $0) })
    }

    /// A test card (a hue sweep over a grey ramp) as it is on the left and
    /// through the LUT on the right.
    static func preview(_ table: Table, width: Int = 512, height: Int = 256) -> CGImage? {
        let half = width / 2
        var pixels = [UInt8](repeating: 255, count: half * height * 4)
        for y in 0..<height {
            for x in 0..<half {
                let index = (y * half + x) * 4
                let u = Double(x) / Double(max(1, half - 1))
                let rgb: (Double, Double, Double)
                if y < height * 2 / 3 {
                    // The buffer runs top down: bright and saturated at the top.
                    let value = 1 - 0.5 * Double(y) / Double(height * 2 / 3)
                    let hue = u * 6
                    let sector = Int(hue) % 6
                    let fraction = hue - floor(hue)
                    let falling = value * (1 - fraction)
                    let rising = value * fraction
                    rgb = [(value, rising, 0), (falling, value, 0), (0, value, rising), (0, falling, value), (rising, 0, value), (value, 0, falling)][sector]
                } else {
                    rgb = (u, u, u)
                }
                pixels[index] = UInt8((rgb.0 * 255).rounded())
                pixels[index + 1] = UInt8((rgb.1 * 255).rounded())
                pixels[index + 2] = UInt8((rgb.2 * 255).rounded())
            }
        }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(pixels) as CFData),
              let card = CGImage(width: half, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: half * 4, space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let filter = CIFilter(name: "CIColorCubeWithColorSpace") else { return nil }
        let before = CIImage(cgImage: card)
        filter.setValue(table.size, forKey: "inputCubeDimension")
        filter.setValue(table.data, forKey: "inputCubeData")
        filter.setValue(space, forKey: "inputColorSpace")
        filter.setValue(before, forKey: kCIInputImageKey)
        guard let after = filter.outputImage else { return nil }
        let divider = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: CGRect(x: half - 1, y: 0, width: 2, height: height))
        let composed = divider
            .composited(over: after.transformed(by: CGAffineTransform(translationX: CGFloat(half), y: 0)))
            .composited(over: before)
        return CIContext().createCGImage(composed, from: CGRect(x: 0, y: 0, width: half * 2, height: height), format: .RGBA8, colorSpace: space)
    }
}
