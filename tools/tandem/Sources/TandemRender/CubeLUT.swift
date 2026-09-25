import CoreImage
import Foundation

/// A colour lookup table read from an Adobe/Resolve `.cube` file. 1D tables
/// are expanded to 3D so both go through `CIColorCube`.
struct CubeLUT: Equatable {
    var title: String?
    var dimension: Int
    /// RGBA float32, red changing fastest, as `CIColorCube` wants.
    var data: [Float]
    var domainMin: [Float] = [0, 0, 0]
    var domainMax: [Float] = [1, 1, 1]

    enum ParseError: Error, CustomStringConvertible {
        case missingSize
        case wrongCount(expected: Int, found: Int)
        case tooLarge(Int)

        var description: String {
            switch self {
            case .missingSize: return "The .cube file has no LUT_3D_SIZE or LUT_1D_SIZE."
            case .wrongCount(let expected, let found): return "The .cube file should have \(expected) entries but has \(found)."
            case .tooLarge(let size): return "LUT size \(size) is larger than 128."
            }
        }
    }

    static func parse(_ text: String) throws -> CubeLUT {
        var title: String?
        var size3D: Int?
        var size1D: Int?
        var domainMin: [Float] = [0, 0, 0]
        var domainMax: [Float] = [1, 1, 1]
        var rows: [[Float]] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
            switch parts[0].uppercased() {
            case "TITLE":
                title = line.dropFirst(5).trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            case "LUT_3D_SIZE":
                size3D = parts.count > 1 ? Int(parts[1]) : nil
            case "LUT_1D_SIZE":
                size1D = parts.count > 1 ? Int(parts[1]) : nil
            case "DOMAIN_MIN":
                domainMin = parts.dropFirst().compactMap { Float($0) }
            case "DOMAIN_MAX":
                domainMax = parts.dropFirst().compactMap { Float($0) }
            default:
                let values = parts.compactMap { Float($0) }
                if values.count == 3 { rows.append(values) }
            }
        }
        if domainMin.count != 3 { domainMin = [0, 0, 0] }
        if domainMax.count != 3 { domainMax = [1, 1, 1] }

        if let n = size3D {
            guard n <= 128 else { throw ParseError.tooLarge(n) }
            guard rows.count == n * n * n else { throw ParseError.wrongCount(expected: n * n * n, found: rows.count) }
            var data = [Float]()
            data.reserveCapacity(rows.count * 4)
            for row in rows { data += [row[0], row[1], row[2], 1] }
            return CubeLUT(title: title, dimension: n, data: data, domainMin: domainMin, domainMax: domainMax)
        }
        if let n = size1D {
            guard rows.count == n else { throw ParseError.wrongCount(expected: n, found: rows.count) }
            // Expand to a 33-point cube, interpolating each channel's curve.
            let dimension = 33
            func curve(_ channel: Int, _ x: Float) -> Float {
                let position = x * Float(n - 1)
                let i = min(Int(position), n - 2)
                let f = position - Float(i)
                return rows[i][channel] * (1 - f) + rows[i + 1][channel] * f
            }
            var data = [Float]()
            data.reserveCapacity(dimension * dimension * dimension * 4)
            for b in 0..<dimension {
                for g in 0..<dimension {
                    for r in 0..<dimension {
                        let step = Float(dimension - 1)
                        data += [curve(0, Float(r) / step), curve(1, Float(g) / step), curve(2, Float(b) / step), 1]
                    }
                }
            }
            return CubeLUT(title: title, dimension: dimension, data: data, domainMin: domainMin, domainMax: domainMax)
        }
        throw ParseError.missingSize
    }

    /// Applies the table. Inputs outside the table's domain are mapped into
    /// it first.
    func apply(to image: CIImage) -> CIImage {
        var input = image
        if domainMin != [0, 0, 0] || domainMax != [1, 1, 1] {
            let scale = (0..<3).map { CGFloat(1 / max(domainMax[$0] - domainMin[$0], 1e-6)) }
            let bias = (0..<3).map { -CGFloat(domainMin[$0]) * scale[$0] }
            input = input.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: scale[0], y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: scale[1], z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: scale[2], w: 0),
                "inputBiasVector": CIVector(x: bias[0], y: bias[1], z: bias[2], w: 0)
            ])
        }
        let bytes = data.withUnsafeBufferPointer { Data(buffer: $0) }
        return input.applyingFilter("CIColorCube", parameters: [
            "inputCubeDimension": dimension,
            "inputCubeData": bytes
        ])
    }
}

/// Parsed LUTs by path and modification date, so a LUT on every camera clip
/// is read once.
final class LUTCache: @unchecked Sendable {
    static let shared = LUTCache()
    private let lock = NSLock()
    private var entries: [String: (modified: Date?, lut: CubeLUT?)] = [:]

    func lut(at url: URL) -> CubeLUT? {
        let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        lock.lock()
        if let entry = entries[url.path], entry.modified == modified {
            lock.unlock()
            return entry.lut
        }
        lock.unlock()
        var lut: CubeLUT?
        if let text = try? String(contentsOf: url, encoding: .utf8) {
            do {
                lut = try CubeLUT.parse(text)
            } catch {
                NSLog("TandemRender: couldn't read LUT \(url.path): \(error)")
            }
        }
        lock.lock()
        entries[url.path] = (modified, lut)
        lock.unlock()
        return lut
    }
}
