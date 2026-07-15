import Foundation
import XCTest
@testable import TaskbarApp

final class FormatterCacheTests: XCTestCase {
    func testDateFormatterCacheKeysByFormatLocaleAndTimeZone() {
        var formatterCount = 0
        let cache = TaskbarDateFormatterCache {
            formatterCount += 1
            return DateFormatter()
        }
        let date = Date(timeIntervalSince1970: 1_000)
        let english = Locale(identifier: "en_US")
        let french = Locale(identifier: "fr_FR")
        let utc = TimeZone(secondsFromGMT: 0)!
        let perth = TimeZone(identifier: "Australia/Perth")!

        _ = cache.string(from: date, format: "HH:mm", locale: english, timeZone: utc)
        _ = cache.string(from: date, format: "HH:mm", locale: english, timeZone: utc)
        XCTAssertEqual(formatterCount, 1)

        _ = cache.string(from: date, format: "HH:mm:ss", locale: english, timeZone: utc)
        _ = cache.string(from: date, format: "HH:mm", locale: french, timeZone: utc)
        _ = cache.string(from: date, format: "HH:mm", locale: english, timeZone: perth)
        XCTAssertEqual(formatterCount, 4)
    }
}
