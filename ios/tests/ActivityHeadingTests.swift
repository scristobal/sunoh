import Foundation
import Testing
@testable import Sunoh

struct ActivityHeadingTests {
    @Test func headingUsesWeekdayDayMonthAndYearWithoutTimeOrDuration() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Vienna"))
        let date = try #require(calendar.date(from: DateComponents(year: 2026, month: 5, day: 2, hour: 9, minute: 55, second: 42)))
        let start = Int64(date.timeIntervalSince1970 * 1_000)
        let activity = ActivitySummary(id: "heading", startedAt: Timestamp(millisecondsSince1970: start),
                                       lastPointAt: Timestamp(millisecondsSince1970: start + (5 * 3_600 + 12 * 60 + 59) * 1_000), pointCount: 20)
        #expect(ActivityHeadingFormatting.title(activity, calendar: calendar) == "Saturday 2, May 2026")
    }

    @Test func headingUsesLocalCalendarDateAcrossYearBoundary() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let date = try #require(calendar.date(from: DateComponents(year: 2026, month: 12, day: 31, hour: 23, minute: 30)))
        let activity = ActivitySummary(id: "heading", startedAt: Timestamp(millisecondsSince1970: Int64(date.timeIntervalSince1970 * 1_000)),
                                       lastPointAt: nil, pointCount: 0)
        #expect(ActivityHeadingFormatting.title(activity, calendar: calendar) == "Thursday 31, December 2026")
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Vienna"))
        #expect(ActivityHeadingFormatting.title(activity, calendar: calendar) == "Friday 1, January 2027")
    }
}
