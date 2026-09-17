import EventKit
import Foundation

struct CalendarAttendee: Codable, Equatable, Sendable {
    let name: String
    let email: String?
    let response: String
}

struct CalendarSuggestion: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let attendees: [CalendarAttendee]
}

enum CalendarRanking {
    static func best(_ events: [CalendarSuggestion], start: Date, end: Date) -> CalendarSuggestion? {
        let duration = max(1, end.timeIntervalSince(start))
        let ranked = events.map { event in
            (event, max(0, min(end, event.end).timeIntervalSince(max(start, event.start))) / duration)
        }.filter { $0.1 >= 0.5 }.sorted { $0.1 > $1.1 }
        guard let first = ranked.first else { return nil }
        if ranked.count > 1, first.1 - ranked[1].1 < 0.2 { return nil }
        return first.0
    }
}

@MainActor
final class CalendarService {
    private let store = EKEventStore()
    var authorized: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }

    func requestAccess() async throws -> Bool { try await store.requestFullAccessToEvents() }

    func calendars() -> [(id: String, title: String)] {
        guard authorized else { return [] }
        return store.calendars(for: .event).map { ($0.calendarIdentifier, "\($0.source.title): \($0.title)") }
    }

    func suggestions(start: Date, end: Date, selectedCalendarIDs: Set<String>) -> [CalendarSuggestion] {
        guard authorized, !selectedCalendarIDs.isEmpty else { return [] }
        let calendars = store.calendars(for: .event).filter { selectedCalendarIDs.contains($0.calendarIdentifier) }
        guard !calendars.isEmpty else { return [] }
        let predicate = store.predicateForEvents(withStart: start.addingTimeInterval(-300), end: end.addingTimeInterval(300), calendars: calendars)
        var seen = Set<String>()
        return store.events(matching: predicate).compactMap { event in
            guard !event.isAllDay, event.status != .canceled,
                  !(event.attendees ?? []).contains(where: { $0.isCurrentUser && $0.participantStatus == .declined }) else { return nil }
            let id = "\(event.calendarItemExternalIdentifier ?? event.eventIdentifier ?? ""):\(event.startDate.timeIntervalSince1970)"
            guard seen.insert(id).inserted else { return nil }
            let people = (event.attendees ?? []).filter { $0.participantType != .resource && $0.participantType != .room }.map { attendee in
                let raw = attendee.url.absoluteString
                let email = raw.hasPrefix("mailto:") ? String(raw.dropFirst(7)).removingPercentEncoding : nil
                return CalendarAttendee(name: attendee.name ?? email ?? "Unnamed guest", email: email,
                                        response: String(attendee.participantStatus.rawValue))
            }
            return CalendarSuggestion(id: id, title: event.title ?? "Meeting", start: event.startDate, end: event.endDate, attendees: people)
        }
    }
}
