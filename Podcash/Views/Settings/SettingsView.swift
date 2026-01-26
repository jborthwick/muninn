import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var allEpisodes: [Episode]

    private var networkMonitor = NetworkMonitor.shared
    private var playerManager = AudioPlayerManager.shared
    private var syncService = SyncService.shared

    @State private var repairResult: String?
    @State private var showRepairResult = false

    private let skipIntervalOptions: [Double] = [5, 10, 15, 30, 45, 60, 90]

    var body: some View {
        NavigationStack {
            List {
                // iCloud Sync section
                Section("iCloud Sync") {
                    HStack {
                        Image(systemName: syncService.isCloudAvailable ? "icloud.fill" : "icloud.slash")
                            .foregroundStyle(syncService.isCloudAvailable ? .blue : .secondary)
                        Text(syncService.isCloudAvailable ? "iCloud Available" : "iCloud Unavailable")
                        Spacer()
                        if syncService.isSyncing {
                            ProgressView()
                        }
                    }

                    Button {
                        Task {
                            await syncService.syncNow(context: modelContext)
                        }
                    } label: {
                        HStack {
                            Image(systemName: "arrow.triangle.2.circlepath")
                            Text("Sync Now")
                        }
                    }
                    .disabled(syncService.isSyncing || !syncService.isCloudAvailable)

                    if let lastSync = syncService.lastSyncDate {
                        HStack {
                            Text("Last synced")
                            Spacer()
                            Text(lastSync.relativeFormatted)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let error = syncService.syncError {
                        HStack {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                // Playback section
                Section("Playback") {
                    Picker("Skip Forward", selection: Binding(
                        get: { playerManager.skipForwardInterval },
                        set: { playerManager.skipForwardInterval = $0 }
                    )) {
                        ForEach(skipIntervalOptions, id: \.self) { interval in
                            Text("\(Int(interval)) seconds").tag(interval)
                        }
                    }

                    Picker("Skip Backward", selection: Binding(
                        get: { playerManager.skipBackwardInterval },
                        set: { playerManager.skipBackwardInterval = $0 }
                    )) {
                        ForEach(skipIntervalOptions, id: \.self) { interval in
                            Text("\(Int(interval)) seconds").tag(interval)
                        }
                    }
                }

                // Developer/Testing section
                Section("Developer") {
                    Toggle(isOn: Binding(
                        get: { networkMonitor.simulateOffline },
                        set: { networkMonitor.simulateOffline = $0 }
                    )) {
                        HStack {
                            Image(systemName: "wifi.slash")
                                .foregroundStyle(.orange)
                            Text("Simulate Offline Mode")
                        }
                    }

                    if networkMonitor.simulateOffline {
                        HStack {
                            Image(systemName: "info.circle")
                                .foregroundStyle(.secondary)
                            Text("App will behave as if offline")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                // Storage/Downloads section
                Section("Storage") {
                    Button {
                        repairDownloads()
                    } label: {
                        HStack {
                            Image(systemName: "wrench.and.screwdriver")
                            Text("Repair Downloads")
                        }
                    }

                    Text("Fixes episodes that show as downloaded but the file is missing")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Button {
                        clearImageCache()
                    } label: {
                        HStack {
                            Image(systemName: "photo.on.rectangle.angled")
                            Text("Clear Image Cache")
                        }
                    }

                    Text("Clears cached podcast artwork images")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // Listening Stats
                Section {
                    NavigationLink {
                        StatsView()
                    } label: {
                        HStack {
                            Image(systemName: "chart.bar.fill")
                                .foregroundStyle(.purple)
                            Text("Listening Stats")
                        }
                    }
                }

                // About
                Section("About") {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text("1.0.0")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Settings")
            .alert("Repair Complete", isPresented: $showRepairResult) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(repairResult ?? "")
            }
        }
    }

    private func repairDownloads() {
        var fixedCount = 0
        let fileManager = FileManager.default

        for episode in allEpisodes {
            if let localPath = episode.localFilePath {
                if !fileManager.fileExists(atPath: localPath) {
                    // File doesn't exist - clear the path
                    episode.localFilePath = nil
                    episode.downloadProgress = nil
                    fixedCount += 1
                }
            }
        }

        try? modelContext.save()

        if fixedCount > 0 {
            repairResult = "Fixed \(fixedCount) episode(s) with missing files. You can now re-download them."
        } else {
            repairResult = "All downloads are valid. No repairs needed."
        }
        showRepairResult = true
    }

    private func clearImageCache() {
        Task {
            await ImageCache.shared.clearCache()
            await MainActor.run {
                repairResult = "Image cache cleared. Artwork will reload."
                showRepairResult = true
            }
        }
    }
}

#Preview {
    SettingsView()
}
