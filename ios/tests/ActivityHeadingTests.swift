import Foundation
import Testing
@testable import Sunoh

struct ActivityHeadingTests {
    @Test func headingUsesLocalStartTimeWithoutDuration() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Vienna"))
        let date = try #require(calendar.date(from: DateComponents(year: 2026, month: 7, day: 18, hour: 8, minute: 12, second: 42)))
        let start = Int64(date.timeIntervalSince1970 * 1_000)
        let activity = ActivitySummary(id: "heading", startedAt: Timestamp(millisecondsSince1970: start),
                                       lastPointAt: Timestamp(millisecondsSince1970: start + (5 * 3_600 + 12 * 60 + 59) * 1_000), pointCount: 20)
        #expect(ActivityHeadingFormatting.title(activity, calendar: calendar) == "Saturday 18, 8:12am")
    }

    @Test func headingUsesTwelveHourClock() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        for (hour, label) in [(0, "12:05am"), (8, "8:05am"), (12, "12:05pm"), (20, "8:05pm")] {
            let date = try #require(calendar.date(from: DateComponents(year: 2026, month: 7, day: 18, hour: hour, minute: 5)))
            let activity = ActivitySummary(id: "heading", startedAt: Timestamp(millisecondsSince1970: Int64(date.timeIntervalSince1970 * 1_000)),
                                           lastPointAt: nil, pointCount: 0)
            #expect(ActivityHeadingFormatting.title(activity, calendar: calendar) == "Saturday 18, \(label)")
        }
    }
}
