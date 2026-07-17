import SwiftUI

struct ChapterGenerationDebugView: View {
    let debug: ChapterGenerationDebugInfo
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                episodeSection
                boundariesSection
                beatsSection
                overviewSection
                errorsSection
            }
            .navigationTitle("Chapter Debug")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var episodeSection: some View {
        Section("Episode") {
            debugRow("Generated", debug.generatedAt.formatted(date: .omitted, time: .standard))
            debugRow("Title", debug.episodeTitle)
            debugRow("Duration", ChapterTitleGenerator.formatTime(debug.episodeDuration))
            debugRow("Source", debug.source)
            debugRow("Succeeded", debug.succeeded ? "Yes" : "No")
            debugRow("Foundation Model", foundationModelAvailabilityLabel)
            if let detail = debug.foundationModelAvailabilityDetail, !detail.isEmpty {
                debugRow("FM detail", detail)
            }
            if debug.segmentCount > 0 {
                debugRow("Transcript segments", "\(debug.segmentCount)")
            }
        }
    }

    @ViewBuilder
    private var boundariesSection: some View {
        if debug.boundaryCount > 0 {
            Section("Boundaries") {
                debugRow("Count", "\(debug.boundaryCount)")
                if !debug.boundariesDescription.isEmpty {
                    debugBlock("Start times", debug.boundariesDescription)
                }
            }
        }
    }

    private var beatsSection: some View {
        Section("Chapter beats (\(debug.beats.count))") {
            if debug.beats.isEmpty {
                Text("No beats captured.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(debug.beats) { beat in
                    beatSection(beat)
                }
            }
        }
    }

    private func beatSection(_ beat: ChapterBeatDebugEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Chapter \(beat.index + 1)")
                .font(.subheadline.weight(.semibold))

            debugRow("Time", "\(ChapterTitleGenerator.formatTime(beat.startTime)) – \(ChapterTitleGenerator.formatTime(beat.endTime))")
            debugRow("Title", beat.title)
            debugRow("Source", beat.source)
            if beat.flaggedRollCall {
                debugRow("Roll-call skip", "Yes", highlight: true)
            }
            if beat.usedChunking {
                debugRow("Chunked transcript", "Yes")
            }
            if beat.transcriptCharacters > 0 {
                debugRow("Transcript chars", "\(beat.transcriptCharacters)")
            }
            if beat.summary.isEmpty {
                debugRow("Summary", "(empty)", highlight: true)
            } else {
                debugBlock("Summary", beat.summary)
            }
            if !beat.excerptPreview.isEmpty {
                debugBlock("Excerpt preview", beat.excerptPreview)
            }
            if let error = beat.error {
                debugRow("Error", error, highlight: true)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var overviewSection: some View {
        if !debug.overview.isEmpty || debug.overviewError != nil {
            Section("Episode overview") {
                if debug.overview.isEmpty {
                    Text("No overview produced.")
                        .foregroundStyle(.secondary)
                } else {
                    Text(debug.overview)
                        .font(.body)
                        .textSelection(.enabled)
                }
                if let error = debug.overviewError {
                    debugRow("Overview error", error, highlight: true)
                }
            }
        }
    }

    @ViewBuilder
    private var errorsSection: some View {
        if debug.generationError != nil || debug.summarySaveError != nil {
            Section("Errors") {
                if let error = debug.generationError {
                    debugRow("Generation", error, highlight: true)
                }
                if let error = debug.summarySaveError {
                    debugRow("Summary save", error, highlight: true)
                }
            }
        }
    }

    private var foundationModelAvailabilityLabel: String {
        guard let available = debug.foundationModelAvailable else {
            return debug.source == "persisted"
                ? "Unknown (persisted snapshot)"
                : "Unknown"
        }
        return available ? "Available" : "Unavailable"
    }

    private func debugRow(_ label: String, _ value: String, highlight: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline)
                .foregroundStyle(highlight ? .orange : .primary)
                .textSelection(.enabled)
        }
        .padding(.vertical, 2)
    }

    private func debugBlock(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
    }
}
