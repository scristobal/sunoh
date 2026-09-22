import Foundation
import Observation

/// Shared presentation timing. Persistence publishes its result immediately;
/// both recording indicators retain saving feedback for at least two seconds.
@MainActor @Observable final class RecordingSaveFeedback {
    private(set) var isVisible = false

    private let minimumDuration: Duration
    private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private var task: Task<Void, Never>?

    init(minimumDuration: Duration = .seconds(2),
         sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.minimumDuration = minimumDuration
        self.sleep = sleep
    }

    func begin() {
        clear()
        guard minimumDuration > .zero else { return }
        isVisible = true
        task = Task { [weak self, minimumDuration, sleep] in
            try? await sleep(minimumDuration)
            guard !Task.isCancelled else { return }
            self?.isVisible = false
            self?.task = nil
        }
    }

    func clear() {
        task?.cancel()
        task = nil
        isVisible = false
    }

    deinit { task?.cancel() }
}
