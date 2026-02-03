import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct ExportImportView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var exportService = ExportImportService.shared
    @State private var showExportOptions = false
    @State private var showImportPicker = false
    @State private var showShareSheet = false
    @State private var exportedFileURL: URL?
    @State private var showAlert = false
    @State private var alertTitle = ""
    @State private var alertMessage = ""
    @State private var isProcessing = false
    
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
                    showImportPicker = true
                } label: {
                    HStack {
                        Image(systemName: "arrow.down.doc")
                            .foregroundStyle(.green)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Import from File")
                                .foregroundStyle(.primary)
                            Text("Restore from a previous export")
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
            handleImport(result: result)
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
    
    private func handleImport(result: Result<[URL], Error>) {
        isProcessing = true
        Task {
            do {
                let urls = try result.get()
                guard let url = urls.first else { return }
                
                try await exportService.importFromFile(url, context: modelContext)
                
                await MainActor.run {
                    alertTitle = "Import Successful"
                    alertMessage = exportService.lastError ?? "Your data has been imported successfully."
                    showAlert = true
                    isProcessing = false
                }
            } catch {
                await MainActor.run {
                    alertTitle = "Import Failed"
                    alertMessage = error.localizedDescription
                    showAlert = true
                    isProcessing = false
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
