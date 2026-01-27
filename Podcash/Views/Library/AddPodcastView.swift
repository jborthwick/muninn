import SwiftUI
import SwiftData

struct AddPodcastView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var inputText = ""
    @State private var results: [PodcastSearchResult] = []
    @State private var isSearching = false
    @State private var isAddingURL = false
    @State private var errorMessage: String?
    @State private var successMessage: String?
    @State private var addingID: String?
    @State private var clipboardURL: String?
    @FocusState private var isInputFocused: Bool

    private var isURL: Bool {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.hasPrefix("http://") ||
               trimmed.hasPrefix("https://") ||
               trimmed.contains(".com/") ||
               trimmed.contains(".org/") ||
               trimmed.contains(".net/") ||
               trimmed.contains(".io/") ||
               trimmed.hasSuffix(".xml") ||
               trimmed.hasSuffix(".rss")
    }

    var body: some View {
        NavigationStack {
            List {
                // Input section
                Section {
                    TextField("Search or paste URL", text: $inputText)
                        .textContentType(.URL)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                        .focused($isInputFocused)
                        .onSubmit {
                            if isURL {
                                addFromURL()
                            }
                        }

                    if let clipboardURL, inputText.isEmpty {
                        Button {
                            inputText = clipboardURL
                        } label: {
                            HStack {
                                Image(systemName: "doc.on.clipboard")
                                Text("Paste from clipboard")
                                Spacer()
                                Text(clipboardURL.prefix(30) + (clipboardURL.count > 30 ? "..." : ""))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                } footer: {
                    if isURL {
                        Text("Press return to add this URL")
                    } else if !inputText.isEmpty {
                        Text("Searching podcasts...")
                    }
                }

                // Success message
                if let successMessage {
                    Section {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text(successMessage)
                        }
                    }
                }

                // Error message
                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }

                // URL add button (when URL detected)
                if isURL && !inputText.isEmpty {
                    Section {
                        Button(action: addFromURL) {
                            HStack {
                                if isAddingURL {
                                    ProgressView()
                                    Text("Adding...")
                                } else {
                                    Image(systemName: "plus.circle.fill")
                                    Text("Add Podcast from URL")
                                }
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .disabled(isAddingURL)
                    }
                }

                // Search results (when not a URL)
                if !isURL {
                    if results.isEmpty && !isSearching && !inputText.isEmpty {
                        ContentUnavailableView(
                            "No Results",
                            systemImage: "magnifyingglass",
                            description: Text("Try a different search term")
                        )
                    }

                    ForEach(results) { result in
                        SearchResultRow(
                            result: result,
                            isAdding: addingID == result.id,
                            onAdd: { await addResult(result) }
                        )
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("Add Podcast")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
            .onAppear {
                // Auto-focus input field
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    isInputFocused = true
                }
                checkClipboard()
            }
            .onChange(of: inputText) { _, newValue in
                if !isURL {
                    Task {
                        await performSearch(query: newValue)
                    }
                } else {
                    results = []
                }
            }
            .overlay {
                if isSearching && results.isEmpty && !isURL {
                    ProgressView("Searching...")
                }
            }
        }
    }

    private func checkClipboard() {
        if let string = UIPasteboard.general.string,
           let url = URL(string: string),
           url.scheme == "http" || url.scheme == "https" {
            clipboardURL = string
        } else {
            clipboardURL = nil
        }
    }

    private func performSearch(query: String) async {
        guard !query.isEmpty else {
            results = []
            return
        }

        // Debounce
        try? await Task.sleep(for: .milliseconds(300))
        guard query == inputText && !isURL else { return }

        isSearching = true
        errorMessage = nil

        do {
            results = try await PodcastLookupService.shared.searchPodcasts(query: query)
        } catch {
            errorMessage = error.localizedDescription
        }

        isSearching = false
    }

    private func addFromURL() {
        var urlString = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !urlString.hasPrefix("http://") && !urlString.hasPrefix("https://") {
            urlString = "https://\(urlString)"
        }

        isAddingURL = true
        errorMessage = nil
        successMessage = nil

        Task {
            do {
                // Resolve URL to RSS feed
                let resolvedURL = try await PodcastLookupService.shared.resolveToRSSFeed(url: urlString)
                try await addPodcast(feedURL: resolvedURL)
                await MainActor.run {
                    successMessage = "Podcast added successfully"
                    inputText = ""
                    isAddingURL = false
                }
            } catch let error as AddPodcastError {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isAddingURL = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isAddingURL = false
                }
            }
        }
    }

    private func addResult(_ result: PodcastSearchResult) async {
        guard let feedURL = result.feedURL else {
            errorMessage = "No RSS feed available for this podcast"
            return
        }

        addingID = result.id
        errorMessage = nil
        successMessage = nil

        do {
            try await addPodcast(feedURL: feedURL, itunesID: result.id)
            successMessage = "Added \(result.title)"
        } catch let error as AddPodcastError {
            errorMessage = error.localizedDescription
        } catch {
            errorMessage = error.localizedDescription
        }

        addingID = nil
    }

    private func addPodcast(feedURL: String, itunesID: String? = nil) async throws {
        // Check if already subscribed
        let descriptor = FetchDescriptor<Podcast>(
            predicate: #Predicate { $0.feedURL == feedURL }
        )
        if let existing = try modelContext.fetch(descriptor).first {
            throw AddPodcastError.alreadySubscribed(existing.title)
        }

        // Fetch and save podcast
        let (podcast, episodes) = try await FeedService.shared.fetchPodcast(from: feedURL)

        await MainActor.run {
            // Store iTunes ID for sharing
            podcast.itunesID = itunesID

            modelContext.insert(podcast)
            for episode in episodes {
                episode.podcast = podcast
                modelContext.insert(episode)
            }
            podcast.episodes = episodes
        }
    }
}

// MARK: - Search Result Row

private struct SearchResultRow: View {
    let result: PodcastSearchResult
    let isAdding: Bool
    let onAdd: () async -> Void

    var body: some View {
        HStack(spacing: 12) {
            CachedAsyncImage(url: URL(string: result.artworkURL ?? "")) { image in
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } placeholder: {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.secondary.opacity(0.2))
                    .overlay {
                        Image(systemName: "mic")
                            .foregroundStyle(.secondary)
                    }
            }
            .frame(width: 50, height: 50)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text(result.title)
                    .font(.headline)
                    .lineLimit(2)

                if let author = result.author {
                    Text(author)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Button {
                Task { await onAdd() }
            } label: {
                if isAdding {
                    ProgressView()
                        .frame(width: 60)
                } else {
                    Text("Add")
                        .frame(width: 60)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isAdding || result.feedURL == nil)
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Errors

enum AddPodcastError: LocalizedError {
    case alreadySubscribed(String)

    var errorDescription: String? {
        switch self {
        case .alreadySubscribed(let title):
            return "Already subscribed to \(title)"
        }
    }
}

#Preview {
    AddPodcastView()
        .modelContainer(for: Podcast.self, inMemory: true)
}
