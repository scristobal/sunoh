import SwiftUI

// MARK: - Activity extensions

extension ActivitySummary {
    var startDate: Foundation.Date {
        startedAt.date
    }

    var dayLabel: String {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEEEdjm")
        return formatter.string(from: startDate)
    }

    /// Standalone presentations need the month and year that the history's
    /// section heading supplies to its shorter row date.
    var dateIntervalLabel: String {
        let formatter = DateIntervalFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: startDate, to: (lastPointAt ?? startedAt).date)
    }

    var endLabel: String {
        let endDate = (lastPointAt ?? startedAt).date
        let calendar = Calendar.current
        let formatter = DateFormatter()
        if calendar.isDate(startDate, inSameDayAs: endDate) {
            formatter.setLocalizedDateFormatFromTemplate("jm")
        } else if !calendar.isDate(startDate, equalTo: endDate, toGranularity: .year) {
            formatter.setLocalizedDateFormatFromTemplate("EEEEdMMMyyyyjm")
        } else if !calendar.isDate(startDate, equalTo: endDate, toGranularity: .month) {
            formatter.setLocalizedDateFormatFromTemplate("EEEEdMMMjm")
        } else {
            formatter.setLocalizedDateFormatFromTemplate("EEEEdjm")
        }
        return formatter.string(from: endDate)
    }

    var year: Int { Calendar.current.component(.year, from: startDate) }
    var month: Int { Calendar.current.component(.month, from: startDate) }
}

// MARK: - Year/Month grouping

private struct YearGroup: Identifiable {
    let id: Int
    let months: [MonthGroup]
}

private struct MonthGroup: Identifiable {
    let id: String
    let label: String
    let activities: [ActivitySummary]
}

private func groupActivitiesByYear(_ activities: [ActivitySummary]) -> [YearGroup] {
    let sorted = activities.sorted { $0.startedAt > $1.startedAt }
    let activitiesByYear = Dictionary(grouping: sorted, by: \.year)
    let monthFormatter = DateFormatter()

    return activitiesByYear.keys.sorted(by: >).map { year in
        let yearActivities = activitiesByYear[year, default: []]
        let activitiesByMonth = Dictionary(grouping: yearActivities, by: \.month)
        let months = activitiesByMonth.keys.sorted(by: >).map { month in
            MonthGroup(
                id: String(format: "%04d-%02d", year, month),
                label: monthFormatter.monthSymbols[month - 1],
                activities: activitiesByMonth[month, default: []]
            )
        }
        return YearGroup(id: year, months: months)
    }
}

// MARK: - Activity row

private struct ActivityRow: View {
    let activity: ActivitySummary
    let library: ActivityLibrary
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                ActivityThumbnail(activityID: activity.id, library: library)
                    .frame(width: 44, height: 44)

                VStack(alignment: .leading, spacing: 4) {
                    Text("\(activity.dayLabel) – \(activity.endLabel)")
                        .font(.headline)
                    Text("\(activity.pointCount) saved points")
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityHint("Opens activity overview")
        .accessibilityIdentifier("activity-row-\(activity.id.rawValue)")
    }
}

// MARK: - Activity list

struct ActivityListView: View {
    let library: ActivityLibrary
    let onSelect: (ActivitySummary) -> Void

    private var years: [YearGroup] {
        guard case .loaded(let saved) = library.history else { return [] }
        return groupActivitiesByYear(saved)
    }

    var body: some View {
        Group {
            if case .failed(let loadError) = library.history {
                ScrollableStatus {
                    ContentUnavailableView {
                        Label("Unable to Load Activities", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(loadError)
                    } actions: {
                        Button("Retry") { Task { await library.reloadHistory() } }
                            .buttonStyle(.bordered)
                            .controlSize(.large)
                    }
                }
            } else if case .loading = library.history {
                ScrollableStatus { ProgressView("Loading activities…") }
            } else if years.isEmpty {
                ScrollableStatus {
                    ContentUnavailableView(
                        "No past activities yet",
                        systemImage: "map",
                        description: Text("Record and save an activity on the map, or import a GPX recording from Profile.")
                    )
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(years) { year in
                            ForEach(year.months) { month in
                                monthSection(month, year: year.id)
                            }
                        }
                    }
                }
            }
        }
        .refreshable { await library.reloadHistory() }
        .scrollEdgeEffectStyle(.soft, for: .top)
    }

    private func monthSection(_ month: MonthGroup, year: Int) -> some View {
        Section {
            ForEach(month.activities) { activity in
                ActivityRow(activity: activity, library: library) { onSelect(activity) }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
            }
        } header: {
            Text(verbatim: "\(month.label) \(year)")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color(uiColor: .systemBackground))
        }
    }
}
