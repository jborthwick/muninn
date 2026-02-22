import SwiftUI
import SwiftData
import UniformTypeIdentifiers

// MARK: - OPML Import Sheet

/// Shown as a sheet after the user picks an OPML file.
/// Parses the file, shows a feed list, then imports with live progress.
struct OPMLImportView: View {
    let fileURL: URL

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    // Parsed feeds
    @State private var feeds: [OPMLFeed] = []
    @State private var parseError: String?

    // Import state
    @State private var isImporting = false
    @State private var processedCount = 0
    @State private var currentFeedTitle = ""
    @State private var result: OPMLImportResult?

    private var importService: ExportImportService { ExportImportService.shared }

    var body: some View {
        NavigationStack {
            Group {
                if let error = parseError {
                    parseErrorView(error)
                } else if isImporting {
                    importProgressView
                } else if let result {
                    importResultView(result)
                } else {
                    feedListView
                }
            }
            .navigationTitle("Import from OPML")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isImporting)
                }
            }
        }
        .onAppear { parseFile() }
        .interactiveDismissDisabled(isImporting)
    }

    // MARK: - Sub-views

    private var feedListView: some View {
        List {
            Section {
                Text("Found \(feeds.count) podcast\(feeds.count == 1 ? "" : "s") in this OPML file.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            let groups = Dictionary(grouping: feeds, by: { $0.groupName })
            let ungrouped = groups[nil] ?? []
            let grouped = groups.filter { $0.key != nil }
                .sorted { ($0.key ?? "") < ($1.key ?? "") }

            // Ungrouped feeds
            if !ungrouped.isEmpty {
                Section("Podcasts") {
                    ForEach(ungrouped, id: \.feedURL) { feed in
                        feedRow(feed)
                    }
                }
            }

            // Grouped feeds
            ForEach(grouped, id: \.key) { key, groupFeeds in
                Section(key ?? "") {
                    ForEach(groupFeeds, id: \.feedURL) { feed in
                        feedRow(feed)
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                startImport()
            } label: {
                Label("Import \(feeds.count) Podcast\(feeds.count == 1 ? "" : "s")",
                      systemImage: "arrow.down.doc.fill")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .padding()
            .background(.regularMaterial)
            .disabled(feeds.isEmpty)
        }
    }

    private var importProgressView: some View {
        VStack(spacing: 24) {
            Spacer()

            ProgressView(value: Double(processedCount), total: Double(max(feeds.count, 1)))
                .progressViewStyle(.linear)
                .padding(.horizontal, 40)

            VStack(spacing: 6) {
                Text("Importing podcasts…")
                    .font(.headline)
                Text("\(processedCount) of \(feeds.count)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if !currentFeedTitle.isEmpty {
                    Text(currentFeedTitle)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .padding(.horizontal, 40)
                }
            }

            Text("This may take a while for large libraries.\nYou can keep using the app while this runs.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Spacer()
        }
    }

    private func importResultView(_ result: OPMLImportResult) -> some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: result.imported > 0 ? "checkmark.circle.fill" : "info.circle.fill")
                .font(.system(size: 60))
                .foregroundStyle(result.imported > 0 ? .green : .secondary)

            VStack(spacing: 8) {
                Text("Import Complete")
                    .font(.title2.weight(.semibold))
                Text(result.summary)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            if result.failed > 0 {
                Text("\(result.failed) podcast\(result.failed == 1 ? "" : "s") could not be fetched and were skipped.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            Spacer()

            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
                .padding(.bottom, 32)
        }
        .padding()
    }

    private func parseErrorView(_ error: String) -> some View {
        ContentUnavailableView {
            Label("Can't Read File", systemImage: "doc.badge.exclamationmark")
        } description: {
            Text(error)
        }
    }

    @ViewBuilder
    private func feedRow(_ feed: OPMLFeed) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(feed.title.isEmpty ? feed.feedURL : feed.title)
                .font(.subheadline)
            Text(feed.feedURL)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Actions

    private func parseFile() {
        let accessing = fileURL.startAccessingSecurityScopedResource()
        defer { if accessing { fileURL.stopAccessingSecurityScopedResource() } }

        do {
            let data = try Data(contentsOf: fileURL)
            let parsed = OPMLParser.parse(data)
            if parsed.isEmpty {
                parseError = "No podcast feeds were found in this file. Make sure it's a valid OPML export."
            } else {
                feeds = parsed
            }
        } catch {
            // Try copying to a temp location first (sandboxed access)
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent(fileURL.lastPathComponent)
            do {
                try? FileManager.default.removeItem(at: tmp)
                try FileManager.default.copyItem(at: fileURL, to: tmp)
                let data = try Data(contentsOf: tmp)
                let parsed = OPMLParser.parse(data)
                if parsed.isEmpty {
                    parseError = "No podcast feeds were found in this file."
                } else {
                    feeds = parsed
                }
            } catch {
                parseError = "Could not read the file: \(error.localizedDescription)"
            }
        }
    }

    private func startImport() {
        isImporting = true
        Task {
            let outcome = await importService.importFromOPML(
                feeds: feeds,
                context: modelContext
            ) { processed, total, title in
                processedCount = processed
                currentFeedTitle = title
            }
            result = outcome
            isImporting = false
        }
    }
}
