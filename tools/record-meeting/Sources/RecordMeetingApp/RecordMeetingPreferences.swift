import Combine
import Foundation

@MainActor
final class RecordMeetingPreferences: ObservableObject {
    private enum Key {
        static let saveDirectory = "saveDirectory"
        static let notionParentPage = "notionParentPage"
        static let notionDataSourceID = "notionDataSourceID"
        static let whisperModel = "whisperModel"
        static let autoPublishToNotion = "autoPublishToNotion"
    }

    private let defaults: UserDefaults

    @Published var saveDirectory: String {
        didSet { defaults.set(saveDirectory, forKey: Key.saveDirectory) }
    }

    @Published var notionParentPage: String {
        didSet { defaults.set(notionParentPage, forKey: Key.notionParentPage) }
    }

    @Published var notionDataSourceID: String {
        didSet { defaults.set(notionDataSourceID, forKey: Key.notionDataSourceID) }
    }

    @Published var whisperModel: String {
        didSet { defaults.set(whisperModel, forKey: Key.whisperModel) }
    }

    @Published var autoPublishToNotion: Bool {
        didSet { defaults.set(autoPublishToNotion, forKey: Key.autoPublishToNotion) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        saveDirectory = defaults.string(forKey: Key.saveDirectory)
            ?? MeetingFiles.defaultDirectory().path
        notionParentPage = defaults.string(forKey: Key.notionParentPage) ?? ""
        notionDataSourceID = defaults.string(forKey: Key.notionDataSourceID) ?? ""
        whisperModel = defaults.string(forKey: Key.whisperModel) ?? "small"
        autoPublishToNotion = defaults.object(forKey: Key.autoPublishToNotion) == nil
            ? true
            : defaults.bool(forKey: Key.autoPublishToNotion)
    }
}
