import SwiftUI

struct RecordingSlider: View {
    let recorder: RecordingController
    let status: RecordingStatus
    let locationUnavailableReason: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric private var handleSize: CGFloat = 52
    @ScaledMetric(relativeTo: .title3) private var symbolSize: CGFloat = 20
    @State private var dragValue: Double?
    @State private var pendingTarget: Bool?
    @State private var arrowDirection: CGFloat
    @State private var isMorphingArrow = false

    init(recorder: RecordingController, status: RecordingStatus, locationUnavailableReason: String) {
        self.recorder = recorder
        self.status = status
        self.locationUnavailableReason = locationUnavailableReason
        _arrowDirection = State(initialValue: recorder.currentRecording?.phase == .recording ? -1 : 1)
    }

    private let commitThreshold: CGFloat = 0.85
    private var isRecording: Bool { recorder.currentRecording?.phase == .recording }
    private var isAtRight: Bool { pendingTarget ?? isRecording }
    private var isEnabled: Bool {
        pendingTarget == nil && !recorder.isChangingRecording && !status.isWorking
            && (recorder.recordingState == .recording || (recorder.recordingState == .idle && status == .ready))
    }
    private var thumbWidth: CGFloat { handleSize * 1.6 }
    private var inset: CGFloat { handleSize / 8 }
    private var trackHeight: CGFloat { handleSize - inset }
    private var position: Double { dragValue ?? (isAtRight ? 1 : 0) }
    private var foregroundColor: Color {
        (isEnabled || pendingTarget != nil ? Color.primary : .secondary).mix(with: .white, by: position)
    }
    private var handleForegroundColor: Color {
        isEnabled || pendingTarget != nil ? .primary : .secondary
    }
    private var handleTint: Color {
        guard isEnabled || pendingTarget != nil else { return Color(.secondarySystemFill) }
        return Color.green.opacity(0.24).mix(with: .white.opacity(0.8), by: position)
    }
    private var isArmed: Bool {
        isEnabled && dragValue != nil && (isRecording ? 1 - position : position) >= commitThreshold
    }

    private var settleAnimation: Animation {
        reduceMotion ? .easeInOut(duration: 0.15) : .spring(duration: 0.4, bounce: 0.2)
    }

    private var title: String {
        switch status {
        case .ready: "Slide to start recording"
        case .recording: "Slide to stop recording"
        case .locationNotReady: locationUnavailableReason
        case .unavailable: recorder.requiresRestart ? "Storage unavailable" : recorder.storageError ?? status.label
        case .working, .stopped: status.label
        }
    }

    var body: some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .multilineTextAlignment(.center)
            .padding(.horizontal, thumbWidth)
            .padding(.vertical, inset)
            .frame(maxWidth: .infinity, minHeight: trackHeight)
            .hidden()
            .overlay {
                GeometryReader { geometry in
                    track(in: geometry.size)
                }
            }
            .animation(settleAnimation, value: isAtRight)
            .onChange(of: isAtRight) { _, atRight in
                isMorphingArrow = true
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) {
                    arrowDirection = atRight ? -1 : 1
                } completion: {
                    isMorphingArrow = false
                }
            }
            .sensoryFeedback(.selection, trigger: isArmed) { _, armed in armed }
            .sensoryFeedback(.impact(weight: .medium), trigger: pendingTarget) { _, target in target != nil }
            .transaction { if reduceMotion { $0.animation = nil } }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .accessibilityValue(isRecording ? "Recording" : "Stopped")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { if isEnabled { commit() } }
            .accessibilityIdentifier("recording-slider")
    }

    private func track(in size: CGSize) -> some View {
        let travel = max(0, size.width - thumbWidth - inset * 2)
        let prompt = isArmed ? (isRecording ? "Release to stop recording" : "Release to start recording") : title

        return Text(prompt)
            .font(.subheadline.weight(.semibold))
            .multilineTextAlignment(.center)
            .foregroundStyle(foregroundColor)
            .contentTransition(.opacity)
            .padding(.horizontal, thumbWidth)
            .frame(width: size.width, height: size.height)
            .animation(.easeInOut(duration: 0.15), value: isArmed)
            .overlay {
                RecordingSlideControl(
                    value: position,
                    enabled: isEnabled,
                    thumbSize: CGSize(width: thumbWidth, height: handleSize),
                    thumbTint: handleTint,
                    onBegan: { dragValue = isAtRight ? 1 : 0 },
                    onChanged: { dragValue = $0 },
                    onEnded: { value, cancelled in
                        let progress = isRecording ? 1 - value : value
                        if isEnabled, !cancelled, progress >= commitThreshold { commit() }
                        dragValue = nil
                    }
                )
                .frame(height: handleSize)
                .padding(.horizontal, inset)
                .accessibilityHidden(true)
            }
            .overlay(alignment: .leading) {
                handleSymbol
                    .frame(width: thumbWidth, height: handleSize)
                    .offset(x: inset + travel * position)
                    .allowsHitTesting(false)
            }
            .glassEffect(.regular.tint(.red.opacity(position)).interactive(isEnabled), in: .capsule)
    }

    private var handleSymbol: some View {
        let showsArrow = isMorphingArrow || isEnabled || pendingTarget != nil

        return ZStack {
            RecordingArrow(direction: arrowDirection)
                .stroke(style: StrokeStyle(lineWidth: symbolSize / 8, lineCap: .round, lineJoin: .round))
                .frame(width: symbolSize, height: symbolSize)
                .opacity(showsArrow ? 1 : 0)

            if !showsArrow {
                if status.isWorking {
                    ProgressView().tint(handleForegroundColor)
                } else {
                    Image(systemName: status.symbol)
                        .font(.title3.weight(.semibold))
                        .contentTransition(.symbolEffect(.replace))
                }
            }
        }
        .foregroundStyle(handleForegroundColor)
        .animation(.easeInOut(duration: 0.12), value: showsArrow)
    }

    private func commit() {
        let start = !isRecording
        withAnimation(settleAnimation) {
            pendingTarget = start
        }
        Task {
            if start { await recorder.startRecording() }
            else { await recorder.stopRecording() }
            withAnimation(settleAnimation) { pendingTarget = nil }
        }
    }
}

private struct RecordingArrow: Shape {
    var direction: CGFloat

    var animatableData: CGFloat {
        get { direction }
        set { direction = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let direction = min(1, max(-1, direction))
        let tip = CGPoint(x: rect.midX + rect.width * 0.4 * direction, y: rect.midY)
        let wingX = rect.midX + rect.width * 0.05 * direction
        let wingHeight = rect.height * 0.3 * abs(direction)

        return Path { path in
            path.move(to: CGPoint(x: rect.minX + rect.width * 0.1, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.1, y: rect.midY))
            path.move(to: CGPoint(x: wingX, y: rect.midY - wingHeight))
            path.addLine(to: tip)
            path.addLine(to: CGPoint(x: wingX, y: rect.midY + wingHeight))
        }
    }
}
