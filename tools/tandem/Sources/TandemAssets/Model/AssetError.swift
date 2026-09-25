import Foundation

/// Errors from the asset library. Messages are written for Mike or an agent
/// to act on, and never include keys.
public enum AssetError: Error, Equatable, Sendable, LocalizedError {
    case notFound(String)
    case invalid(String)
    case unsupported(String)
    /// The provider is off (no key, not agreed to, or a stub).
    case providerUnavailable(provider: String, reason: String)
    /// The key works but isn't allowed to do this, for example an
    /// ElevenLabs key without the `sound_generation` permission.
    case permission(provider: String, message: String)
    case rateLimited(provider: String, retryAfter: TimeInterval)
    case http(provider: String, status: Int, message: String)
    case network(provider: String, message: String)
    case normaliseFailed(String)
    case database(String)

    public var errorDescription: String? {
        switch self {
        case .notFound(let what): return "Not found: \(what)"
        case .invalid(let message): return message
        case .unsupported(let message): return message
        case .providerUnavailable(let provider, let reason): return "\(provider) is unavailable: \(reason)"
        case .permission(let provider, let message): return "\(provider) refused: \(message)"
        case .rateLimited(let provider, let retryAfter):
            return "\(provider) rate limit reached, try again in \(Int(retryAfter.rounded(.up))) s"
        case .http(let provider, let status, let message): return "\(provider) returned HTTP \(status): \(message)"
        case .network(let provider, let message): return "\(provider) network error: \(message)"
        case .normaliseFailed(let message): return "Normalising failed: \(message)"
        case .database(let message): return "Asset catalogue error: \(message)"
        }
    }
}
