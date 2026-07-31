import Foundation

func detailedErrorDescription(_ error: Error) -> String {
    var messages: [String] = []
    var identifiers: [String] = []
    var current: NSError? = error as NSError
    var visited: Set<ObjectIdentifier> = []

    while let candidate = current, visited.insert(ObjectIdentifier(candidate)).inserted {
        for message in [
            candidate.localizedDescription,
            candidate.localizedFailureReason,
            candidate.localizedRecoverySuggestion
        ].compactMap({ $0 }) where !message.isEmpty && !messages.contains(message) {
            messages.append(message)
        }
        identifiers.append("\(candidate.domain) \(candidate.code)")
        current = candidate.userInfo[NSUnderlyingErrorKey] as? NSError
    }

    let explanation = messages.joined(separator: ". ")
    let diagnostic = identifiers.joined(separator: ", ")
    return explanation.isEmpty ? diagnostic : "\(explanation) [\(diagnostic)]"
}
