import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.miniPlayerVisible) private var miniPlayerVisible
    @Query private var allEpisodes: [Episode]
    @Query private var settings: [AppSettings]

    private var networkMonitor = NetworkMonitor.shared
    private var playerManager = AudioPlayerManager.shared
    private var syncService = SyncService.shared

    @State private var repairResult: String?
    @State private var showRepairResult = false
    @State private var showDeleteConfirmation = false
    @State private var downloadSize: Int64 = 0

    private let skipIntervalOptions: [Double] = [5, 10, 15, 30, 45, 60, 90]
    private let storageLimitOptions: [(label: String, value: Int)] = [
        ("Unlimited", 0),
        ("1 GB", 1),
        ("2 GB", 2),
        ("5 GB", 5),
        ("10 GB", 10)
    ]
    private let keepLatestOptions: [(label: String, value: Int)] = [
        ("Unlimited", 0),
        ("1 episode", 1),
        ("3 episodes", 3),
        ("5 episodes", 5),
        ("10 episodes", 10)
    ]

    private var appSettings: AppSettings {
        settings.first ?? AppSettings.getOrCreate(context: modelContext)
    }

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

                // Downloads section
                Section("Downloads") {
                    // Storage used
                    HStack {
                        Text("Storage Used")
                        Spacer()
                        Text(formatBytes(downloadSize))
                            .foregroundStyle(.secondary)
                    }

                    // Manual download network preference
                    Picker("Manual Downloads", selection: Binding(
                        get: { appSettings.downloadPreferenceRaw },
                        set: { appSettings.downloadPreferenceRaw = $0 }
                    )) {
                        ForEach(DownloadPreference.allCases, id: \.rawValue) { pref in
                            Text(pref.label).tag(pref.rawValue)
                        }
                    }

                    // Auto-download network preference
                    Picker("Auto-Downloads", selection: Binding(
                        get: { appSettings.autoDownloadPreferenceRaw },
                        set: { appSettings.autoDownloadPreferenceRaw = $0 }
                    )) {
                        ForEach(DownloadPreference.allCases, id: \.rawValue) { pref in
                            Text(pref.label).tag(pref.rawValue)
                        }
                    }

                    // Storage limit picker
                    Picker("Storage Limit", selection: Binding(
                        get: { appSettings.storageLimitGB },
                        set: { appSettings.storageLimitGB = $0 }
                    )) {
                        ForEach(storageLimitOptions, id: \.value) { option in
                            Text(option.label).tag(option.value)
                        }
                    }

                    // Keep latest N per podcast
                    Picker("Keep Per Podcast", selection: Binding(
                        get: { appSettings.keepLatestDownloadsPerPodcast },
                        set: { appSettings.keepLatestDownloadsPerPodcast = $0 }
                    )) {
                        ForEach(keepLatestOptions, id: \.value) { option in
                            Text(option.label).tag(option.value)
                        }
                    }

                    Text("Completed episodes are auto-deleted. Starred and queued episodes are protected.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Toggle(isOn: Binding(
                        get: { networkMonitor.simulateOffline },
                        set: { networkMonitor.simulateOffline = $0 }
                    )) {
                        HStack {
                            Image(systemName: "wifi.slash")
                                .foregroundStyle(.orange)
                            Text("Offline Mode")
                        }
                    }

                    if networkMonitor.simulateOffline {
                        HStack {
                            Image(systemName: "info.circle")
                                .foregroundStyle(.secondary)
                            Text("Only downloaded episodes will be available")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                // Storage management section
                Section {
                    Button(role: .destructive) {
                        showDeleteConfirmation = true
                    } label: {
                        HStack {
                            Image(systemName: "trash")
                            Text("Delete All Downloads")
                        }
                    }

                    Button {
                        repairDownloads()
                    } label: {
                        HStack {
                            Image(systemName: "wrench.and.screwdriver")
                            Text("Repair Downloads")
                        }
                    }

                    Button {
                        clearImageCache()
                    } label: {
                        HStack {
                            Image(systemName: "photo.on.rectangle.angled")
                            Text("Clear Image Cache")
                        }
                    }
                }

                // Data Management
                Section("Data") {
                    NavigationLink {
                        ExportImportView()
                    } label: {
                        HStack {
                            Image(systemName: "arrow.up.arrow.down.circle.fill")
                                .foregroundStyle(.blue)
                            Text("Export & Import")
                        }
                    }
                    
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

                // Debug & Diagnostics
                Section("Debug") {
                    NavigationLink {
                        CrashLogsView()
                    } label: {
                        HStack {
                            Image(systemName: "ladybug.fill")
                                .foregroundStyle(.red)
                            Text("Crash Logs")
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
            .contentMargins(.bottom, miniPlayerVisible ? 60 : 0, for: .scrollContent)
            .navigationTitle("Settings")
            .onAppear {
                updateDownloadSize()
            }
            .alert("Repair Complete", isPresented: $showRepairResult) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(repairResult ?? "")
            }
            .confirmationDialog(
                "Delete All Downloads?",
                isPresented: $showDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete All", role: .destructive) {
                    deleteAllDownloads()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will delete all downloaded episodes except starred and queued ones.")
            }
        }
    }

    private func updateDownloadSize() {
        downloadSize = DownloadManager.shared.totalDownloadSize(context: modelContext)
    }

    private func deleteAllDownloads() {
        DownloadCleanupService.shared.deleteAllUnprotectedDownloads(context: modelContext)
        updateDownloadSize()
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
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
