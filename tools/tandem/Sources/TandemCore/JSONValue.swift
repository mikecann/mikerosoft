import Foundation

/// Arbitrary JSON, used for merge patches and structured props.
public enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let v): try container.encode(v)
        case .number(let v): try container.encode(v)
        case .string(let v): try container.encode(v)
        case .array(let v): try container.encode(v)
        case .object(let v): try container.encode(v)
        }
    }

    /// Applies this value as an RFC 7396 merge patch to `target`.
    /// Objects merge key by key, `null` deletes a key, anything else replaces.
    public func mergePatch(into target: JSONValue) -> JSONValue {
        guard case .object(let patch) = self else { return self }
        var result: [String: JSONValue]
        if case .object(let existing) = target { result = existing } else { result = [:] }
        for (key, value) in patch {
            if case .null = value {
                result.removeValue(forKey: key)
            } else {
                result[key] = value.mergePatch(into: result[key] ?? .null)
            }
        }
        return .object(result)
    }

    /// Converts any `Encodable` value to `JSONValue`.
    public static func from<T: Encodable>(_ value: T) throws -> JSONValue {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// Decodes this JSON into a `Decodable` type.
    public func decode<T: Decodable>(as type: T.Type) throws -> T {
        let data = try JSONEncoder().encode(self)
        return try JSONDecoder().decode(type, from: data)
    }
}

extension JSONValue {
    /// The merge patch that turns `old` into `new`: only the keys whose
    /// values differ, with `null` for keys `new` doesn't have. Nil when
    /// they're the same. Applied to something that has changed since
    /// `old`, it leaves the other changes alone.
    public static func mergePatch(from old: JSONValue, to new: JSONValue) -> JSONValue? {
        guard case .object(let before) = old, case .object(let after) = new else {
            return old == new ? nil : new
        }
        var patch: [String: JSONValue] = [:]
        for (key, value) in after {
            guard let previous = before[key] else {
                patch[key] = value
                continue
            }
            if case .object = previous, case .object = value {
                if let inner = mergePatch(from: previous, to: value) { patch[key] = inner }
            } else if previous != value {
                patch[key] = value
            }
        }
        for key in before.keys where after[key] == nil {
            patch[key] = .null
        }
        return patch.isEmpty ? nil : .object(patch)
    }

    /// Applies a merge patch to a `Codable` value by round-tripping it
    /// through JSON. Keys the patch doesn't mention are left alone.
    public static func applyMergePatch<T: Codable>(_ patch: JSONValue, to value: T) throws -> T {
        let current = try JSONValue.from(value)
        let merged = patch.mergePatch(into: current)
        return try merged.decode(as: T.self)
    }
}
