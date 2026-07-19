import SwiftUI

/// Spoiler-gated community synopsis: compact card opens a full-text sheet.
struct CommunitySynopsisView: View {
    let insight: EpisodeInsight
    @State private var showDetail = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Community synopsis")
                .font(.headline)

            Button {
                showDetail = true
            } label: {
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.title3)
                        .foregroundStyle(.orange)
                        .frame(width: 28)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Contains spoilers for this episode")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)

                        Text("Tap to read the community plot summary")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                    }

                    Spacer(minLength: 0)

                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .glassEffect(.regular, in: .rect(cornerRadius: 14))
            .accessibilityHint("Opens the full community synopsis")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(isPresented: $showDetail) {
            CommunitySynopsisDetailView(insight: insight)
        }
    }
}

/// Full spoiler-bearing community synopsis sheet.
private struct CommunitySynopsisDetailView: View {
    let insight: EpisodeInsight
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Label(
                        "Contains spoilers for this episode",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.orange)

                    if let synopsis = insight.synopsis {
                        Text(synopsis)
                            .font(.body)
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    HStack(alignment: .firstTextBaseline) {
                        Text("Sourced from \(insight.attribution)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if let urlString = insight.sourceURL, let url = URL(string: urlString) {
                            Link(destination: url) {
                                Label("Open episode page", systemImage: "safari")
                                    .font(.caption.weight(.semibold))
                            }
                        }
                    }
                    .padding(.top, 4)

                    Text("Community synopsis from the fan wiki. May contain full-episode spoilers.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("Synopsis")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}
