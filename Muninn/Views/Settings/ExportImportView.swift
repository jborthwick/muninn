import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct ExportImportView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var exportService = ExportImportService.shared
    @State private var showExportOptions = false
    @State private var showImportPicker = false
    @State private var showOPMLPicker = false
    @State private var opmlImportURL: URL?
    @State private var showShareSheet = false
    @State private var exportedFileURL: URL?
    @State private var showAlert = false
    @State private var alertTitle = ""
    @State private var alertMessage = ""
    @State private var isProcessing = false
    @State private var showImportOptions = false
    @State private var selectedImportURL: URL?
    @State private var replaceExistingData = true
    
    var body: some View {
        List {
            Section {
                Text("Export your data to transfer to another device or back up your library.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            
            Section("Export") {
                Button {
                    exportPodcastsOnly()
                } label: {
                    HStack {
                        Image(systemName: "arrow.up.doc")
                            .foregroundStyle(.blue)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Export Podcasts Only")
                                .foregroundStyle(.primary)
                            Text("Just your podcast subscriptions")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .disabled(isProcessing)
                
                Button {
                    exportFullData()
                } label: {
                    HStack {
                        Image(systemName: "arrow.up.doc.fill")
                            .foregroundStyle(.purple)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Export Full Data")
                                .foregroundStyle(.primary)
                            Text("Podcasts, folders, stars, playback progress, queue, and settings")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .disabled(isProcessing)
            }
            
            Section("Import") {
                Button {
                    showOPMLPicker = true
                } label: {
                    HStack {
                        Image(systemName: "arrow.down.doc.fill")
                            .foregroundStyle(.teal)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Import from OPML")
                                .foregroundStyle(.primary)
                            Text("Migrate from Overcast, Pocket Casts, Castro, and others")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .disabled(isProcessing)

                Button {
                    showImportPicker = true
                } label: {
                    HStack {
                        Image(systemName: "arrow.down.doc")
                            .foregroundStyle(.green)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Import from File")
                                .foregroundStyle(.primary)
                            Text("Restore from a previous Muninn export")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .disabled(isProcessing)
            }
            
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Label("What gets exported?", systemImage: "info.circle")
                        .font(.subheadline.bold())
                    
                    VStack(alignment: .leading, spacing: 8) {
                        ExportInfoRow(icon: "mic.fill", text: "Podcast subscriptions")
                        ExportInfoRow(icon: "folder.fill", text: "Folders and organization")
                        ExportInfoRow(icon: "star.fill", text: "Starred episodes")
                        ExportInfoRow(icon: "checkmark.circle.fill", text: "Played/unplayed status")
                        ExportInfoRow(icon: "waveform", text: "Playback positions")
                        ExportInfoRow(icon: "list.bullet", text: "Queue")
                        ExportInfoRow(icon: "gearshape.fill", text: "App settings")
                    }
                    
                    Text("Note: Downloads are not included. You'll need to re-download episodes after importing.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .padding(.top, 4)
                }
                .padding(.vertical, 4)
            }
            
            if isProcessing {
                Section {
                    HStack {
                        ProgressView()
                        Text(exportService.isExporting ? "Exporting..." : "Importing...")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Export & Import")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showShareSheet) {
            if let url = exportedFileURL {
                ShareSheet(items: [url])
            }
        }
        .fileImporter(
            isPresented: $showImportPicker,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            handleFileSelection(result: result)
        }
        .fileImporter(
            isPresented: $showOPMLPicker,
            allowedContentTypes: [.xml, .plainText],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                opmlImportURL = url
            }
        }
        .sheet(isPresented: Binding(
            get: { opmlImportURL != nil },
            set: { if !$0 { opmlImportURL = nil } }
        )) {
            if let url = opmlImportURL {
                OPMLImportView(fileURL: url)
            }
        }
        .confirmationDialog(
            "Import Options",
            isPresented: $showImportOptions,
            titleVisibility: .visible
        ) {
            Button("Replace All Data") {
                replaceExistingData = true
                performImport()
            }
            Button("Merge with Existing") {
                replaceExistingData = false
                performImport()
            }
            Button("Cancel", role: .cancel) {
                selectedImportURL = nil
            }
        } message: {
            Text("Choose how to import:\n\n• Replace All: Deletes existing data first (recommended for migration)\n• Merge: Adds to existing data")
        }
        .alert(alertTitle, isPresented: $showAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertMessage)
        }
    }
    
    private func exportPodcastsOnly() {
        isProcessing = true
        Task {
            do {
                let url = try await MainActor.run {
                    try exportService.exportPodcastsOnly(context: modelContext)
                }
                await MainActor.run {
                    exportedFileURL = url
                    showShareSheet = true
                    isProcessing = false
                }
            } catch {
                await MainActor.run {
                    alertTitle = "Export Failed"
                    alertMessage = error.localizedDescription
                    showAlert = true
                    isProcessing = false
                }
            }
        }
    }
    
    private func exportFullData() {
        isProcessing = true
        Task {
            do {
                let url = try await MainActor.run {
                    try exportService.exportFullData(context: modelContext)
                }
                await MainActor.run {
                    exportedFileURL = url
                    showShareSheet = true
                    isProcessing = false
                }
            } catch {
                await MainActor.run {
                    alertTitle = "Export Failed"
                    alertMessage = error.localizedDescription
                    showAlert = true
                    isProcessing = false
                }
            }
        }
    }
    
    private func handleFileSelection(result: Result<[URL], Error>) {
        do {
            let urls = try result.get()
            guard let url = urls.first else { return }
            selectedImportURL = url
            showImportOptions = true
        } catch {
            alertTitle = "File Selection Failed"
            alertMessage = error.localizedDescription
            showAlert = true
        }
    }
    
    private func performImport() {
        guard let url = selectedImportURL else { return }
        
        isProcessing = true
        Task {
            do {
                try await exportService.importFromFile(url, context: modelContext, replaceExisting: replaceExistingData)
                
                await MainActor.run {
                    alertTitle = "Import Successful - Restart Required"
                    let baseMessage = exportService.lastError ?? "Your data has been imported successfully."
                    alertMessage = baseMessage + "\n\n⚠️ IMPORTANT: You must completely close and restart the app for episodes to appear.\n\n1. Swipe up from app switcher\n2. Reopen the app\n3. Episodes will then be visible"
                    showAlert = true
                    isProcessing = false
                    selectedImportURL = nil
                }
            } catch {
                await MainActor.run {
                    alertTitle = "Import Failed"
                    alertMessage = error.localizedDescription
                    showAlert = true
                    isProcessing = false
                    selectedImportURL = nil
                }
            }
        }
    }
}

struct ExportInfoRow: View {
    let icon: String
    let text: String
    
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    NavigationStack {
        ExportImportView()
    }
}
