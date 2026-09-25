import Foundation
import TandemAssets
import TandemCore

/// An error any client can show as it is. `message` is written for people
/// (and agents); `code` is stable for programs to branch on.
public struct ServiceError: Error, Codable, Equatable, CustomStringConvertible, LocalizedError, Sendable {
    public enum Code: String, Codable, Sendable {
        /// The request couldn't be read: bad JSON, a missing field, a bad time.
        case badRequest
        case notFound
        /// The edit doesn't make sense (Core's `EditError.invalid`).
        case invalid
        case overlap
        /// A locked track, or the project is open somewhere else.
        case locked
        /// `expectedRevision` didn't match. Re-read and try again.
        case staleRevision
        /// The feature needs a module that isn't built yet.
        case notImplemented
        /// Something needed isn't there, like the app for a screenshot.
        case unavailable
        case nothingToUndo
        case nothingToRedo
        case unauthorized
        case internalError
    }

    public var code: String
    public var message: String
    /// The project's revision when it matters, for example after a stale
    /// revision.
    public var revision: Int?

    public init(_ code: Code, _ message: String, revision: Int? = nil) {
        self.code = code.rawValue
        self.message = message
        self.revision = revision
    }

    public var description: String { message }
    public var errorDescription: String? { message }

    public var knownCode: Code? { Code(rawValue: code) }

    /// The HTTP status the local server sends for this error.
    public var httpStatus: Int {
        switch knownCode {
        case .badRequest, .invalid: return 400
        case .unauthorized: return 401
        case .notFound: return 404
        case .overlap, .locked, .staleRevision, .nothingToUndo, .nothingToRedo: return 409
        case .notImplemented: return 501
        case .unavailable: return 503
        case .internalError, .none: return 500
        }
    }

    /// Turns any error into a `ServiceError`, keeping the human wording of
    /// `EditError` and making decoding errors readable.
    public static func wrap(_ error: Error) -> ServiceError {
        switch error {
        case let error as ServiceError:
            return error
        case let error as EditError:
            switch error {
            case .notFound: return ServiceError(.notFound, error.description)
            case .overlap: return ServiceError(.overlap, error.description)
            case .locked: return ServiceError(.locked, error.description)
            case .invalid: return ServiceError(.invalid, error.description)
            case .staleRevision(_, let actual): return ServiceError(.staleRevision, error.description, revision: actual)
            case .notImplemented(let what):
                return ServiceError(.notImplemented, "\(what) isn't built yet, so this doesn't work in this version of Tandem.")
            }
        case let error as DecodingError:
            return ServiceError(.badRequest, DecodingErrorText.describe(error))
        case let error as AssetError:
            let message = error.errorDescription ?? "\(error)"
            switch error {
            case .notFound: return ServiceError(.notFound, message)
            case .invalid, .unsupported: return ServiceError(.invalid, message)
            case .providerUnavailable, .permission, .rateLimited, .http, .network: return ServiceError(.unavailable, message)
            case .normaliseFailed, .database: return ServiceError(.internalError, message)
            }
        case let error as CancellationError:
            return ServiceError(.unavailable, "Cancelled. \(error.localizedDescription)")
        default:
            return ServiceError(.internalError, error.localizedDescription)
        }
    }
}

/// The error body the HTTP server sends: `{"error": {...}}`.
public struct ErrorEnvelope: Codable, Sendable {
    public var error: ServiceError

    public init(error: ServiceError) {
        self.error = error
    }
}

/// Swift's decoding errors name coding keys and contexts. Agents do better
/// with a path and a plain sentence: `commands[1].blade: missing "at"`.
public enum DecodingErrorText {
    public static func describe(_ error: DecodingError) -> String {
        switch error {
        case .keyNotFound(let key, let context):
            return "\(prefix(context.codingPath))missing \"\(key.stringValue)\""
        case .typeMismatch(let type, let context):
            return "\(prefix(context.codingPath))expected \(name(of: type))\(detail(context))"
        case .valueNotFound(let type, let context):
            return "\(prefix(context.codingPath))expected \(name(of: type)) but found null"
        case .dataCorrupted(let context):
            if context.codingPath.isEmpty {
                return "The JSON couldn't be read: \(underlying(context))"
            }
            return "\(prefix(context.codingPath))\(underlying(context))"
        @unknown default:
            return "The request couldn't be read."
        }
    }

    /// `commands[1].blade.at` from a coding path.
    public static func path(_ codingPath: [CodingKey]) -> String {
        var text = ""
        for key in codingPath {
            if let index = key.intValue {
                text += "[\(index)]"
            } else {
                text += text.isEmpty ? key.stringValue : ".\(key.stringValue)"
            }
        }
        return text
    }

    private static func prefix(_ codingPath: [CodingKey]) -> String {
        let text = path(codingPath)
        return text.isEmpty ? "" : "\(text): "
    }

    private static func underlying(_ context: DecodingError.Context) -> String {
        let text = context.debugDescription
        if text.hasPrefix("Invalid number of keys found, expected one") {
            return "an edit command is an object with exactly one key, the command name, like {\"blade\": {\"at\": 12.5}}"
        }
        if text.hasPrefix("Cannot initialize"), let range = text.range(of: "from invalid String value ") {
            return "\(text[range.upperBound...]) isn't one of the allowed values"
        }
        return text
    }

    private static func detail(_ context: DecodingError.Context) -> String {
        let text = context.debugDescription
        if text.contains("but found") {
            if let range = text.range(of: "but found") {
                return " \(text[range.lowerBound...])".replacingOccurrences(of: " instead.", with: "")
            }
        }
        return ""
    }

    private static func name(of type: Any.Type) -> String {
        let raw = String(describing: type)
        switch raw {
        case "Double", "Float", "Int", "Int64", "Int32", "Time": return "a number"
        case "String": return "a string"
        case "Bool": return "true or false"
        default:
            if raw.hasPrefix("Array") { return "an array" }
            if raw.hasPrefix("Dictionary") { return "an object" }
            return raw
        }
    }
}
