import SwiftUI

struct PauseRecapDebugView: View {
    let debug: PauseRecapDebugInfo
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                playbackSection
                beatsSection
                partialSection
                generationSection
                outputSection
            }
            .navigationTitle("Recap Debug")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var playbackSection: some View {
        Section("Playback") {
            debugRow("Generated", debug.generatedAt.formatted(date: .omitted, time: .standard))
            debugRow("Paused at", ChapterTitleGenerator.formatTime(debug.pausedAt))
        }
    }

    private var beatsSection: some View {
        Section("Chapter beats") {
            debugRow("Total beats in summary", "\(debug.totalBeatCount)")
            debugRow("Completed before pause", "\(debug.completedBeatCount)")
            if debug.skippedEmptyBeatCount > 0 {
                debugRow("Skipped empty summaries", "\(debug.skippedEmptyBeatCount)", highlight: true)
            }
            if debug.cappedBeatCount > 0 {
                debugRow("Capped to recent", "\(debug.cappedBeatCount)", highlight: true)
            }
            if debug.beatInput.isEmpty {
                debugRow("Input to recap", "None")
            } else {
                debugBlock("Input to recap", debug.beatInput)
            }
        }
    }

    @ViewBuilder
    private var partialSection: some View {
        if debug.hasInProgressChapter {
            Section("In-progress chapter") {
                if let title = debug.inProgressChapterTitle {
                    debugRow("Title", title)
                }
                if let range = debug.inProgressRange {
                    debugRow("Heard range", range)
                }
                if let partial = debug.partialSummary {
                    debugBlock("Partial summary", partial)
                }
                if let excerpt = debug.partialExcerptPreview, !excerpt.isEmpty {
                    debugBlock("Heard excerpt (preview)", excerpt)
                }
            }
        }
    }

    private var generationSection: some View {
        Section("Recap generation") {
            debugRow("Used Foundation Model", debug.usedFoundationModel ? "Yes" : "No")
            debugRow("Direct join (no recompress)", debug.usedDirectJoin ? "Yes" : "No")
            debugRow("Lexical fallback", debug.usedFallback ? "Yes" : "No")
            debugRow("Needs chapters", debug.needsChapters ? "Yes" : "No")
            if !debug.recapPrompt.isEmpty {
                debugBlock("Prompt", debug.recapPrompt)
            }
            if let raw = debug.recapRawResponse {
                debugBlock("Raw response", raw)
            }
            if let error = debug.recapError {
                debugRow("Error", error, highlight: true)
            }
        }
    }

    private var outputSection: some View {
        Section("Final output") {
            if debug.recapFinalText.isEmpty {
                Text("No recap text produced.")
                    .foregroundStyle(.secondary)
            } else {
                Text(debug.recapFinalText)
                    .font(.body)
                    .textSelection(.enabled)
            }
        }
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
