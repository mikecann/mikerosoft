import Foundation
import TandemCore
import TandemMedia
import TandemRender

/// The command surface shared by the local server, the CLI and MCP.
public enum TandemAPI {
    public static let version = "0.1.0"
}

/// Everything an agent can ask of a project. The HTTP server serves each one
/// at `POST /v1/<name>`, the CLI has a command for each, and MCP has a tool
/// for each, all backed by the same `ServiceCall` request and result types.
public enum ServiceOperation: String, CaseIterable, Codable, Sendable {
    case status
    case media
    case timeline
    case transcript
    case search
    case pauses
    case tighten
    case apply
    case undo
    case redo
    case history
    case validate
    case frame
    case screenshot
    case clip
    case export
    case loudness
    case watch
    case effects

    /// The request type that carries this operation's parameters.
    public var callType: any ServiceCall.Type {
        switch self {
        case .status: return StatusRequest.self
        case .media: return MediaRequest.self
        case .timeline: return TimelineRequest.self
        case .transcript: return TranscriptRequest.self
        case .search: return SearchRequest.self
        case .pauses: return PausesRequest.self
        case .tighten: return TightenRequest.self
        case .apply: return ApplyRequest.self
        case .undo: return UndoRequest.self
        case .redo: return RedoRequest.self
        case .history: return HistoryRequest.self
        case .validate: return ValidateRequest.self
        case .frame: return FrameRequest.self
        case .screenshot: return ScreenshotRequest.self
        case .clip: return ClipRequest.self
        case .export: return ExportRequest.self
        case .loudness: return LoudnessRequest.self
        case .watch: return WatchRequest.self
        case .effects: return EffectsRequest.self
        }
    }

    /// True for operations that change the project.
    public var edits: Bool {
        switch self {
        case .apply, .undo, .redo, .tighten, .media: return true
        default: return false
        }
    }
}

/// Who is asking. Edits without an explicit author are credited to
/// `author`, so they show up in the app's activity feed and undo menu under
/// the agent's name.
public struct CallContext: Sendable {
    public var author: String

    public init(author: String = "agent") {
        self.author = author
    }
}

/// A request to the service. Each operation has one request type, decoded
/// from the HTTP body, the MCP tool arguments or the CLI flags, and one
/// result type that encodes to JSON and reads well as text.
public protocol ServiceCall: Codable, Sendable {
    associatedtype Result: Codable & Sendable & ReadableResult
    static var operation: ServiceOperation { get }
    func run(on service: TandemService, context: CallContext) async throws -> Result
}

/// A result that can describe itself in plain text, for the CLI and for
/// agents reading MCP tool output.
public protocol ReadableResult {
    var readableText: String { get }
}

/// JSON coding shared by every transport, so a result reads the same over
/// HTTP, MCP and `--json`.
public enum ServiceJSON {
    public static func encoder(pretty: Bool = false) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty
            ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            : [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return decoder
    }

    /// Decodes a request body. An empty body means "no parameters".
    public static func decodeRequest<C: Decodable>(_ type: C.Type, from data: Data) throws -> C {
        let body = data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) ? Data("{}".utf8) : data
        do {
            return try decoder().decode(type, from: body)
        } catch let error as DecodingError {
            throw ServiceError(.badRequest, DecodingErrorText.describe(error))
        }
    }
}
