import SwiftUI

struct OfflineStorageBar: View {
    @Environment(OfflineMaps.self) private var offline
    @Environment(\.scenePhase) private var scenePhase
    @State private var availableBytes: Int64?

    private var fractionUsed: Double {
        guard let availableBytes else { return 0 }
        let used = Double(offline.storageBytes)
        return used / max(used + Double(availableBytes), 1)
    }

    var body: some View {
        VStack {
            ProgressView(value: fractionUsed)
                .progressViewStyle(.linear)
                .tint(.primary)
            HStack {
                Text("\(offline.storageText) used")
                Spacer()
                Text(availableBytes.map { "\(OfflineMaps.formatBytes($0)) available" } ?? "Space unavailable")
            }
            .font(.subheadline)
            .monospacedDigit()
        }
        .onAppear { offline.refreshStorage(); refreshAvailableStorage() }
        .onChange(of: offline.storageBytes) { refreshAvailableStorage() }
        .onChange(of: scenePhase) { if scenePhase == .active { refreshAvailableStorage() } }
    }

    private func refreshAvailableStorage() {
        let directory = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        let values = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        availableBytes = values?.volumeAvailableCapacityForImportantUsage.map { max($0, 0) }
    }
}
