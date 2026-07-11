import SwiftUI

struct PlaylistSelectionActionBar: View {
    let selectedCount: Int
    let totalCount: Int
    let allSelected: Bool
    let hasSelection: Bool
    let hasUndownloaded: Bool
    let hasDownloaded: Bool
    let onToggleSelectAll: () -> Void
    let onPlayNext: () -> Void
    let onAddToQueue: () -> Void
    let onDownload: () -> Void
    let onDeleteDownloads: () -> Void
    let onMarkPlayed: (Bool) -> Void
    let onStar: (Bool) -> Void
    let onRemoveFromPlaylist: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onToggleSelectAll) {
                HStack(spacing: 8) {
                    Image(systemName: allSelected ? "checkmark.circle.fill"
                                    : (hasSelection ? "minus.circle.fill" : "circle"))
                        .font(.title3)
                        .foregroundStyle(hasSelection ? Color.accentColor : .secondary)
                        .contentTransition(.symbolEffect(.replace))
                    Text(hasSelection ? "\(selectedCount) Selected" : "Tap start, hold end")
                        .font(.subheadline.weight(.medium))
                        .animation(nil, value: selectedCount)
                }
            }
            .buttonStyle(.plain)

            Spacer(minLength: 8)

            HStack(spacing: 2) {
                Button(action: onPlayNext) {
                    Image(systemName: "text.line.first.and.arrowtriangle.forward")
                        .font(.title3)
                        .frame(width: 40, height: 40)
                }
                .disabled(!hasSelection)

                Button(action: onAddToQueue) {
                    Image(systemName: "text.badge.plus")
                        .font(.title3)
                        .frame(width: 40, height: 40)
                }
                .disabled(!hasSelection)

                Menu {
                    if hasUndownloaded {
                        Button(action: onDownload) {
                            Label("Download", systemImage: "arrow.down.circle")
                        }
                    }
                    if hasDownloaded {
                        Button(role: .destructive, action: onDeleteDownloads) {
                            Label("Delete Downloads", systemImage: "trash")
                        }
                    }
                    Divider()
                    Button { onMarkPlayed(true) } label: {
                        Label("Mark as Played", systemImage: "checkmark.circle")
                    }
                    Button { onMarkPlayed(false) } label: {
                        Label("Mark as Unplayed", systemImage: "circle")
                    }
                    Divider()
                    Button { onStar(true) } label: {
                        Label("Star", systemImage: "star")
                    }
                    Button { onStar(false) } label: {
                        Label("Unstar", systemImage: "star.slash")
                    }
                    Divider()
                    Button(role: .destructive, action: onRemoveFromPlaylist) {
                        Label("Remove from Playlist", systemImage: "minus.circle")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title3)
                        .frame(width: 40, height: 40)
                }
                .disabled(!hasSelection)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .modifier(GlassBackgroundModifier())
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
