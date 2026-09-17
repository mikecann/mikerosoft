import Foundation
import XCTest
@testable import MeetingArchiveApp

final class CalendarRankingTests: XCTestCase {
    func testClearOverlapSuggestsTitleButEqualOverlapsStayAmbiguous() {
        let start = Date(timeIntervalSince1970: 1000)
        let end = start.addingTimeInterval(1800)
        let a = CalendarSuggestion(id: "a", title: "Planning", start: start, end: end, attendees: [])
        let b = CalendarSuggestion(id: "b", title: "Other", start: start, end: end, attendees: [])
        XCTAssertEqual(CalendarRanking.best([a], start: start, end: end)?.id, "a")
        XCTAssertNil(CalendarRanking.best([a, b], start: start, end: end))
    }

    func testNonOverlappingCalendarEventDoesNotNameRecording() {
        let start = Date(timeIntervalSince1970: 1000)
        let event = CalendarSuggestion(id: "a", title: "Earlier", start: start.addingTimeInterval(-200), end: start, attendees: [])
        XCTAssertNil(CalendarRanking.best([event], start: start, end: start.addingTimeInterval(100)))
    }
}
