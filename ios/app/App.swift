import SwiftUI

@main struct SunohApp: App {
    private struct Ready { let recorder: RecordingController; let library: ActivityLibrary; let location: LocationTracker }
    private enum Startup { case idle, opening, ready(Ready), failed(String) }
    @Environment(\.scenePhase) private var scenePhase
    @State private var startup: Startup = .idle
    @State private var liveActivity = RecordingActivityController()

    var body: some Scene {
        WindowGroup {
            Group {
                #if DEBUG
                if UITestFixture.isReference {
                    NativeControlsAuditView()
                } else {
                    appContent
                }
                #else
                appContent
                #endif
            }
            .task { await openDatabase() }
            .onChange(of: scenePhase) {
                guard scenePhase == .active, case .ready(let ready) = startup else { return }
                ready.location.activate()
                Task { await ready.recorder.refresh(); await ready.library.reloadHistory() }
            }
            .preferredColorScheme(.light)
            .tint(.black)
        }
    }

    @ViewBuilder private var appContent: some View {
        switch startup {
        case .ready(let ready):
            MainView(tracker: ready.location, recorder: ready.recorder, library: ready.library)
        case .failed(let message):
            ScrollableStatus {
                ContentUnavailableView {
                    Label("Unable to Open Recordings", systemImage: "externaldrive.badge.exclamationmark")
                } description: { Text(message) } actions: {
                    Button("Retry") { Task { await openDatabase() } }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                }
            }
        case .idle, .opening: ScrollableStatus { ProgressView("Opening recordings…") }
        }
    }

    private func openDatabase() async {
        #if DEBUG
        if UITestFixture.isReference { return }
        if UITestFixture.scenario == "startup-error" {
            startup = .failed("Sunō could not open the activity store. Your existing recordings have not been changed. Restart the app and try again.")
            return
        }
        #endif
        switch startup { case .opening, .ready: return; case .idle, .failed: break }
        startup = .opening
        do {
            let repository: ActivityRepository
            #if DEBUG
            if UITestFixture.scenario != nil {
                repository = try await UITestFixture.repository()
            } else {
                repository = try await ActivityRepository.open()
            }
            #else
            repository = try await ActivityRepository.open()
            #endif
            #if DEBUG && targetEnvironment(simulator)
            if ProcessInfo.processInfo.arguments.contains("--seed") {
                let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
                try await repository.importSeed(from: documents.appendingPathComponent("seed.jsonl"))
                // This simulator-only launch acts as a command for `just seed`.
                // Exit only after the repository has saved and verified the import.
                exit(EXIT_SUCCESS)
            }
            #endif
            let recorder = RecordingController(repository: repository)
            let library = ActivityLibrary(repository: repository)
            recorder.onCompleted = { [weak library] activity in await library?.didComplete(activity) }
            library.onStorageFailure = { [weak recorder] error in recorder?.reportStorageFailure(error) }
            try await recorder.restore()
            #if DEBUG
            if UITestFixture.scenario == "storage-error" {
                recorder.reportStorageFailure(.storage("The activity store could not be opened. Your saved recordings are still on this device."))
            }
            #endif
            let location = LocationTracker(onPoints: recorder.record)
            startup = .ready(Ready(recorder: recorder, library: library, location: location))
            liveActivity.startObserving(recorder: recorder, location: location)
            location.activate()
            await library.reloadHistory()
        } catch {
            #if DEBUG && targetEnvironment(simulator)
            if ProcessInfo.processInfo.arguments.contains("--seed") {
                print("SUNOH_SEED_ERROR \(error.localizedDescription)")
                exit(EXIT_FAILURE)
            }
            #endif
            startup = .failed(error.localizedDescription)
        }
    }
}
