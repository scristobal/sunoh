import SwiftUI

struct ActivityHeading: View {
    let activity: ActivitySummary
    let analysis: ActivityAnalysis?
    var processingFailed = false

    var body: some View {
        VStack(alignment: .leading) {
            Text(ActivityHeadingFormatting.title(activity))
                .font(.headline)
                .accessibilityIdentifier("activity-heading-date")
            Text(skiAreas)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("activity-ski-areas")
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var skiAreas: String {
        if processingFailed { return "Ski areas unavailable" }
        guard let analysis else { return "Identifying ski areas…" }
        guard let matching = analysis.timeline?.skiMatches else { return "Ski area not identified" }
        if matching.failure != nil { return "Ski areas unavailable" }
        return matching.resorts.isEmpty ? "Ski area not identified" : matching.resorts.map(\.displayName).joined(separator: " · ")
    }
}

enum ActivityHeadingFormatting {
    static func title(_ activity: ActivitySummary, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "EEEE d, h:mma"
        formatter.amSymbol = "am"
        formatter.pmSymbol = "pm"
        return formatter.string(from: activity.startedAt.date)
    }
}
