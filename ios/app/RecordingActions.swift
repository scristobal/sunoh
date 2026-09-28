import SwiftUI

struct RecordingSlider: View {
    let recorder: RecordingController
    let status: RecordingStatus
    let locationUnavailableReason: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric private var handleSize: CGFloat = 52
    @GestureState(resetTransaction: Transaction(animation: .spring(duration: 0.4, bounce: 0.2)))
    private var dragOffset: CGFloat?
    @State private var pendingTarget: Bool?

    private let commitThreshold: CGFloat = 0.85
    private var isRecording: Bool { recorder.currentRecording?.phase == .recording }
    private var isAtRight: Bool { pendingTarget ?? isRecording }
    private var isEnabled: Bool {
        pendingTarget == nil && !recorder.isChangingRecording && !status.isWorking
            && (recorder.recordingState == .recording || (recorder.recordingState == .idle && status == .ready))
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
            .padding(.horizontal, handleSize)
            .padding(.vertical)
            .frame(maxWidth: .infinity, minHeight: handleSize * 1.25)
            .hidden()
            .overlay {
                GeometryReader { geometry in
                    track(in: geometry.size)
                }
            }
            .animation(settleAnimation, value: isAtRight)
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
        let inset = max(0, (size.height - handleSize) / 2)
        let travel = max(0, size.width - handleSize - inset * 2)
        let translation = isEnabled ? dragOffset ?? 0 : 0
        let distance = isRecording ? -translation : translation
        let progress = travel > 0 ? min(1, max(0, distance / travel)) : 0
        let position = min(travel, max(0, (isAtRight ? travel : 0) + translation))
        let isArmed = isEnabled && dragOffset != nil && progress >= commitThreshold
        let prompt = isArmed ? (isRecording ? "Release to stop recording" : "Release to start recording") : title

        return ZStack(alignment: .leading) {
            Capsule().fill(Color(.secondarySystemFill))

            Capsule()
                .fill(Color.red.opacity(0.16))
                .frame(width: position + handleSize + inset * 2)
                .opacity(isAtRight ? 1 : min(1, progress * 3))
                .allowsHitTesting(false)

            Text(prompt)
                .font(.subheadline.weight(.semibold))
                .multilineTextAlignment(.center)
                .foregroundStyle(isAtRight ? Color.red : isEnabled ? .primary : .secondary)
                .contentTransition(.opacity)
                .opacity(isArmed ? 1 : max(0, 1 - progress * 4))
                .padding(.horizontal, handleSize)
                .frame(maxWidth: .infinity)
                .animation(.easeInOut(duration: 0.15), value: isArmed)
                .allowsHitTesting(false)

            handle(isArmed: isArmed)
                .offset(x: inset + position)
                .gesture(
                    DragGesture(minimumDistance: 5)
                        .updating($dragOffset) { value, offset, transaction in
                            guard isEnabled else { return }
                            transaction.animation = nil
                            offset = value.translation.width
                        }
                        .onEnded { value in
                            let distance = isRecording ? -value.translation.width : value.translation.width
                            if isEnabled, travel > 0, distance >= travel * commitThreshold {
                                commit()
                            }
                        }
                )
        }
        .sensoryFeedback(.selection, trigger: isArmed) { _, armed in armed }
    }

    private func handle(isArmed: Bool) -> some View {
        ZStack {
            if status.isWorking {
                ProgressView()
                    .tint(isAtRight ? .white : .primary)
            } else {
                Image(systemName: handleSymbol(isArmed: isArmed))
                    .font(.title3.weight(.semibold))
                    .contentTransition(.symbolEffect(.replace))
                    .foregroundStyle(isAtRight ? Color.white : isEnabled ? .primary : .secondary)
            }
        }
        .frame(width: handleSize, height: handleSize)
        .glassEffect(.regular.tint(isAtRight ? .red : nil).interactive(isEnabled), in: .circle)
        .contentShape(.circle)
    }

    private func handleSymbol(isArmed: Bool) -> String {
        if !isEnabled && pendingTarget == nil { return status.symbol }
        if isArmed { return isRecording ? "stop.fill" : "record.circle" }
        return isAtRight ? "arrow.left" : "arrow.right"
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
