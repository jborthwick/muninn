import SwiftUI

struct CrashLogsView: View {
    @State private var crashReports: [URL] = []
    @State private var selectedReport: URL?
    @State private var showReportSheet = false
    @State private var reportContent: String = ""
    @State private var showDeleteConfirmation = false
    
    var body: some View {
        NavigationStack {
            Group {
                if crashReports.isEmpty {
                    ContentUnavailableView(
                        "No Crash Reports",
                        systemImage: "checkmark.circle",
                        description: Text("No crashes have been recorded")
                    )
                } else {
                    List {
                        Section {
                            Text("Crash reports are saved locally and can help diagnose issues.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        
                        Section("Crash Reports") {
                            ForEach(crashReports, id: \.self) { report in
                                Button {
                                    selectedReport = report
                                    loadReport(report)
                                    showReportSheet = true
                                } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(report.lastPathComponent)
                                            .font(.subheadline)
                                            .foregroundStyle(.primary)
                                        
                                        if let date = getFileDate(report) {
                                            Text(date.formatted(date: .abbreviated, time: .shortened))
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                            .onDelete(perform: deleteReports)
                        }
                    }
                }
            }
            .navigationTitle("Crash Logs")
            .toolbar {
                if !crashReports.isEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            Button(role: .destructive) {
                                showDeleteConfirmation = true
                            } label: {
                                Label("Delete All", systemImage: "trash")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                }
            }
            .sheet(isPresented: $showReportSheet) {
                if let report = selectedReport {
                    NavigationStack {
                        ScrollView {
                            Text(reportContent)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .padding()
                        }
                        .navigationTitle(report.lastPathComponent)
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Close") {
                                    showReportSheet = false
                                    selectedReport = nil
                                }
                            }
                            
                            ToolbarItem(placement: .primaryAction) {
                                ShareLink(item: reportContent)
                            }
                        }
                    }
                }
            }
            .confirmationDialog(
                "Delete All Crash Reports?",
                isPresented: $showDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete All", role: .destructive) {
                    CrashReporter.shared.clearCrashReports()
                    loadReports()
                }
                Button("Cancel", role: .cancel) {}
            }
            .onAppear {
                loadReports()
            }
        }
    }
    
    private func loadReports() {
        crashReports = CrashReporter.shared.getCrashReports()
    }
    
    private func loadReport(_ url: URL) {
        do {
            reportContent = try String(contentsOf: url, encoding: .utf8)
        } catch {
            reportContent = "Failed to load report: \(error.localizedDescription)"
        }
    }
    
    private func deleteReports(at offsets: IndexSet) {
        for index in offsets {
            let report = crashReports[index]
            try? FileManager.default.removeItem(at: report)
        }
        loadReports()
    }
    
    private func getFileDate(_ url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.creationDateKey]).creationDate
    }
}

#Preview {
    CrashLogsView()
}
