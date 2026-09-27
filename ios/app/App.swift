import SwiftUI
import UIKit

@main struct SunohApp: App {
    private struct Ready { let recorder: RecordingController; let library: ActivityLibrary; let location: LocationTracker }
    private enum Startup { case idle, opening, ready(Ready), failed(String) }
    @Environment(\.scenePhase) private var scenePhase
    @State private var startup: Startup = .idle
    @State private var liveActivity = RecordingActivityController()

    var body: some Scene {
        WindowGroup {
            appContent
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
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--seed") {
                UIApplication.shared.isIdleTimerDisabled = true
                defer { UIApplication.shared.isIdleTimerDisabled = false }
                let arguments = ProcessInfo.processInfo.arguments
                guard let flag = arguments.firstIndex(of: "--seed"), arguments.indices.contains(flag + 1) else {
                    throw GPXError.invalid("Provide a directory of GPX seed files.")
                }
                let directory = URL(fileURLWithPath: arguments[flag + 1], isDirectory: true,
                                    relativeTo: URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true))
                let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                    .filter { $0.pathExtension.lowercased() == "gpx" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
                guard !files.isEmpty else { throw GPXError.noTracks }
                var imported = 0, skipped = 0
                for file in files {
                    let result = try await repository.importSeed(from: file)
                    imported += result.imported.count; skipped += result.skipped
                    print("SUNOH_SEED_FILE \(file.lastPathComponent) imported=\(result.imported.count) skipped=\(result.skipped)")
                }
                if directory.deletingLastPathComponent().standardizedFileURL == FileManager.default.temporaryDirectory.standardizedFileURL,
                   directory.lastPathComponent.hasPrefix("sunoh-device-seed-") || directory.lastPathComponent == "sunoh-seed" {
                    try FileManager.default.removeItem(at: directory)
                }
                print("SUNOH_SEED_OK imported=\(imported) skipped=\(skipped)")
                // This Debug launch acts as a command for the development seed workflow.
                // Exit only after every GPX import has been saved.
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
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--seed") {
                print("SUNOH_SEED_ERROR \(error.localizedDescription)")
                exit(EXIT_FAILURE)
            }
            #endif
            startup = .failed(error.localizedDescription)
        }
    }
}
