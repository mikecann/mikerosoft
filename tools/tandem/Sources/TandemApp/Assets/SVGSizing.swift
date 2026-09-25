import Foundation

/// Many logo SVGs (SVGL's, for one) size themselves `width="1em"`, which
/// AppKit draws as a speck. For thumbnails the root element gets its
/// viewBox's size instead.
enum SVGSizing {
    static func sized(_ svg: String) -> String {
        guard let open = svg.range(of: "<svg"), let close = svg[open.upperBound...].firstIndex(of: ">") else { return svg }
        let tag = String(svg[open.lowerBound..<close])
        guard let viewBox = attribute("viewBox", in: tag) else { return svg }
        let numbers = viewBox.split(whereSeparator: { $0 == " " || $0 == "," }).compactMap { Double($0) }
        guard numbers.count == 4, numbers[2] > 0, numbers[3] > 0 else { return svg }
        let width = attribute("width", in: tag)
        let height = attribute("height", in: tag)
        func absolute(_ value: String?) -> Bool {
            guard let value else { return false }
            return Double(value.replacingOccurrences(of: "px", with: "")) != nil
        }
        guard !(absolute(width) && absolute(height)) else { return svg }
        var rewritten = tag
        for name in ["width", "height"] {
            rewritten = rewritten.replacingOccurrences(of: #" \#(name)="[^"]*""#, with: "", options: .regularExpression)
        }
        rewritten += " width=\"\(format(numbers[2]))\" height=\"\(format(numbers[3]))\""
        return svg.replacingCharacters(in: open.lowerBound..<close, with: rewritten)
    }

    /// Four digit hex colours as six (`#ffff` is `#ffffff`), eight as six:
    /// AppKit's SVG reader skips both, so a white logo draws as nothing.
    static func readableColours(_ svg: String) -> String {
        var result = ""
        var rest = Substring(svg)
        let pattern = ##"="#([0-9a-fA-F]{8}|[0-9a-fA-F]{4})""##
        while let range = rest.range(of: pattern, options: .regularExpression) {
            result += rest[..<range.lowerBound]
            let hex = rest[range].dropFirst(3).dropLast()
            let rgb = hex.count == 8 ? String(hex.prefix(6)) : hex.prefix(3).map { "\($0)\($0)" }.joined()
            result += "=\"#\(rgb)\""
            rest = rest[range.upperBound...]
        }
        return result + rest
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        guard let range = tag.range(of: #" \#(name)="([^"]*)""#, options: .regularExpression) else { return nil }
        let match = tag[range]
        guard let first = match.firstIndex(of: "\""), let last = match.lastIndex(of: "\""), first < last else { return nil }
        return String(match[match.index(after: first)..<last])
    }

    private static func format(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }
}
