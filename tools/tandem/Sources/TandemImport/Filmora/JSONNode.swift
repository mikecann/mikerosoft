import Foundation

/// A forgiving read-only view over parsed JSON.
///
/// Filmora's project JSON is loosely typed: numbers turn up as ints or
/// doubles, flags as bools or 0/1, and several fields are JSON documents
/// stored as strings (`pipBuf`, `scriptBuf`, `speedParam`). Strict
/// `Decodable` models would reject a whole project over one odd field, so
/// the importer reads through these accessors instead, which return nil
/// rather than throwing.
struct JSONNode {
    let raw: Any?

    init(_ raw: Any?) {
        self.raw = raw
    }

    /// Parses JSON data. Returns an empty node for anything unparsable.
    init(data: Data) {
        raw = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    /// Parses JSON held in a string, as Filmora does for nested documents.
    /// Trailing NUL padding is ignored.
    init(jsonString: String) {
        let trimmed = jsonString.trimmingCharacters(in: CharacterSet(charactersIn: "\u{0}").union(.whitespacesAndNewlines))
        self.init(data: Data(trimmed.utf8))
    }

    static let missing = JSONNode(nil)

    subscript(key: String) -> JSONNode {
        JSONNode((raw as? [String: Any])?[key])
    }

    subscript(index: Int) -> JSONNode {
        guard let array = raw as? [Any], array.indices.contains(index) else { return .missing }
        return JSONNode(array[index])
    }

    var exists: Bool {
        guard let raw else { return false }
        return !(raw is NSNull)
    }

    var object: [String: JSONNode]? {
        (raw as? [String: Any])?.mapValues { JSONNode($0) }
    }

    var array: [JSONNode] {
        (raw as? [Any])?.map { JSONNode($0) } ?? []
    }

    var string: String? {
        raw as? String
    }

    var double: Double? {
        if let number = raw as? NSNumber, !isBoolean(number) { return number.doubleValue }
        if let string = raw as? String { return Double(string) }
        return nil
    }

    /// Large integers (Filmora ticks run past 2^32) read exactly.
    var int64: Int64? {
        if let number = raw as? NSNumber, !isBoolean(number) {
            let value = number.doubleValue
            if value.rounded() == value, abs(value) < 9.0e15 { return number.int64Value }
            return Int64(value.rounded())
        }
        if let string = raw as? String { return Int64(string) ?? Double(string).map { Int64($0.rounded()) } }
        return nil
    }

    var int: Int? { int64.map { Int($0) } }

    /// True for `true`, non-zero numbers and "true"/"1".
    var bool: Bool? {
        if let number = raw as? NSNumber {
            return isBoolean(number) ? number.boolValue : number.doubleValue != 0
        }
        if let string = raw as? String {
            switch string.lowercased() {
            case "true", "1": return true
            case "false", "0": return false
            default: return nil
            }
        }
        return nil
    }

    /// The node itself, or the JSON document inside it when it's a string.
    var embedded: JSONNode {
        if let string = raw as? String { return JSONNode(jsonString: string) }
        return self
    }

    private func isBoolean(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }
}
