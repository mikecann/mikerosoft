import Foundation

/// `telemprompit://next` and friends, so a Stream Deck button or a shell
/// script (`open -g telemprompit://next`) can drive the prompter.
enum RemoteCommand: String, CaseIterable {
    case next, previous, restart, end
    case play, pause
    case toggleScrolling = "toggle"
    case faster, slower
    case paste

    init?(url: URL) {
        guard url.scheme?.lowercased() == "telemprompit" else { return nil }
        let name = (url.host ?? url.path(percentEncoded: false))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .lowercased()
        self.init(rawValue: name)
    }

    @MainActor
    func perform(on model: PrompterModel) {
        switch self {
        case .next: model.next()
        case .previous: model.previous()
        case .restart: model.restart()
        case .end: model.end()
        case .play: model.startScrolling()
        case .pause: model.stopScrolling()
        case .toggleScrolling: model.toggleScrolling()
        case .faster: model.changeSpeed(by: 1.2)
        case .slower: model.changeSpeed(by: 1 / 1.2)
        case .paste: model.pasteFromClipboard()
        }
    }
}
