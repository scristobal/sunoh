import SwiftUI
import UIKit

private enum AppTab {
    case map, activities, profile
}

struct MainView: View {
    let tracker: LocationTracker
    let recorder: RecordingController
    let library: ActivityLibrary

    @Environment(\.openURL) private var openURL
    @State private var selectedTab: AppTab = .map
    @State private var selectedActivity: ActivitySummary?
    @State private var showLocationAccessAlert = false
    @State private var showSaveDecision = false

    var body: some View {
        tabs
            .onChange(of: selectedTab, initial: true) {
                if selectedTab == .map { requestMapLocationAccess() }
            }
            .onChange(of: recorder.needsSaveDecision, initial: true) {
                showSaveDecision = recorder.needsSaveDecision
            }
            .alert("Save this recording?", isPresented: $showSaveDecision) {
                Button("Save", role: .cancel) { Task { await recorder.finishRecording() } }
                Button("Discard", role: .destructive) { Task { await recorder.discardRecording() } }
            } message: {
                Text("This recording has fewer than 10 points or lasted less than 1 minute. You can save it or discard it.")
            }
            .alert("Location access needed", isPresented: $showLocationAccessAlert) {
                if tracker.authorizationStatus == .denied {
                    Button("Open Sunō Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            openURL(url)
                        }
                    }
                    Button("Not Now", role: .cancel) {}
                } else {
                    Button("OK", role: .cancel) {}
                }
            } message: {
                if tracker.authorizationStatus == .restricted {
                    Text("Location access is restricted on this device. Check Screen Time or device management restrictions.")
                } else {
                    Text("Allow location access in Settings → Apps → Sunō → Location. Select While Using the App.")
                }
            }
            .onOpenURL { url in
                guard url.scheme == "sunoh", url.host == "explore" else { return }
                selectedTab = .map
            }
    }

    private func requestMapLocationAccess() {
        tracker.activate()
        showLocationAccessAlert = tracker.authorizationStatus == .denied || tracker.authorizationStatus == .restricted
    }

    private var tabs: some View {
        TabView(selection: $selectedTab) {
            Tab("Map", systemImage: "map", value: AppTab.map) {
                NavigationStack {
                    MapScreen(tracker: tracker, recorder: recorder)
                        .navigationTitle("Live")
                        .navigationBarTitleDisplayMode(.inline)
                }
            }

            Tab("Activities", systemImage: "calendar", value: .activities) {
                NavigationStack {
                    ActivityListView(library: library) { selectedActivity = $0 }
                        .navigationTitle("Activities")
                        .navigationBarTitleDisplayMode(.inline)
                }
                .sheet(item: $selectedActivity) { activity in
                    NavigationStack {
                        ActivityOverviewView(activityID: activity.id, library: library)
                    }
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
                }
            }

            Tab("Profile", systemImage: "person.crop.circle", value: .profile) {
                NavigationStack {
                    ProfileView(library: library, tracker: tracker)
                        .navigationTitle("Profile")
                        .navigationBarTitleDisplayMode(.inline)
                }
            }
        }
        .tint(.black)
    }
}
