import SwiftUI

struct RefreshStatusBanner: View {
    var refreshManager = RefreshManager.shared

    var body: some View {
        if refreshManager.isRefreshing {
            HStack(spacing: 8) {
                ProgressView()
                    .scaleEffect(0.8)

                Text("Refreshing \(refreshManager.refreshedCount)/\(refreshManager.totalCount)...")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
            .background(Color.secondary.opacity(0.1))
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}
