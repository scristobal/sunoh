import SwiftUI

struct ActivityElevationProfile: View {
    private let profile: ActivityElevationProfileData

    init(geometry: TrackGeometry) {
        profile = ActivityElevationProfileData(geometry: geometry)
    }

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                if let maximum = profile.maximumElevationMeters {
                    elevation(maximum)
                        .accessibilityIdentifier("elevation-profile-maximum")
                }
                Spacer()
                if let start = profile.startedAt, let end = profile.endedAt {
                    Text("\(TimelineFormatting.time(start)) – \(TimelineFormatting.time(end))")
                        .accessibilityIdentifier("elevation-profile-time-range")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if profile.sections.isEmpty {
                Text("No elevation recorded")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("no-elevation-state")
            } else {
                Canvas { context, size in
                    draw(in: context, size: size)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                HStack {
                    if let minimum = profile.minimumElevationMeters {
                        elevation(minimum)
                            .accessibilityIdentifier("elevation-profile-minimum")
                    }
                    Spacer()
                    Text(TimelineFormatting.duration(Int64(profile.durationSeconds * 1_000)))
                        .accessibilityIdentifier("elevation-profile-duration")
                }
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("activity-elevation-profile")
    }

    private func draw(in context: GraphicsContext, size: CGSize) {
        guard let minimum = profile.minimumElevationMeters, let maximum = profile.maximumElevationMeters,
              size.width > 2, size.height > 2 else { return }
        let bounds = CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1)
        let scale = max(abs(minimum), abs(maximum), 1)
        let range = maximum / scale - minimum / scale
        func position(_ sample: ActivityElevationProfileData.Sample) -> CGPoint {
            let x = profile.durationSeconds > 0 ? sample.elapsedSeconds / profile.durationSeconds : 0.5
            let fraction = range > 0 ? (sample.elevationMeters / scale - minimum / scale) / range : 0.5
            return CGPoint(x: bounds.minX + bounds.width * x, y: bounds.maxY - bounds.height * fraction)
        }
        var baseline = Path()
        baseline.move(to: CGPoint(x: bounds.minX, y: bounds.maxY))
        baseline.addLine(to: CGPoint(x: bounds.maxX, y: bounds.maxY))
        context.stroke(baseline, with: .color(.secondary.opacity(0.15)), lineWidth: 0.5)

        for section in profile.sections {
            guard let first = section.first, let last = section.last else { continue }
            let start = position(first)
            if section.count == 1 {
                context.fill(Path(ellipseIn: CGRect(x: start.x - 1.5, y: start.y - 1.5, width: 3, height: 3)), with: .color(.blue))
                continue
            }
            var line = Path()
            line.move(to: start)
            for sample in section.dropFirst() { line.addLine(to: position(sample)) }
            var fill = line
            fill.addLine(to: CGPoint(x: position(last).x, y: bounds.maxY))
            fill.addLine(to: CGPoint(x: start.x, y: bounds.maxY))
            fill.closeSubpath()
            context.fill(fill, with: .linearGradient(Gradient(colors: [.blue.opacity(0.18), .blue.opacity(0.02)]),
                                                     startPoint: CGPoint(x: 0, y: bounds.minY), endPoint: CGPoint(x: 0, y: bounds.maxY)))
            context.stroke(line, with: .color(.blue), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
    }

    private func elevation(_ meters: Double) -> some View {
        Text("\(meters, format: .number.precision(.fractionLength(0))) m")
    }
}
