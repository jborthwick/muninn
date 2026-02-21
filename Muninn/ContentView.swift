import SwiftUI
import SwiftData

// Environment key for mini player visibility
private struct MiniPlayerVisibleKey: EnvironmentKey {
    static let defaultValue: Bool = false
}

extension EnvironmentValues {
    var miniPlayerVisible: Bool {
        get { self[MiniPlayerVisibleKey.self] }
        set { self[MiniPlayerVisibleKey.self] = newValue }
    }
}

struct ContentView: View {
    private var playerManager = AudioPlayerManager.shared
    private var refreshManager = RefreshManager.shared
    private var networkMonitor = NetworkMonitor.shared
    @Query(sort: \QueueItem.sortOrder) private var queueItems: [QueueItem]
    @State private var showNowPlaying = false

    private var isMiniPlayerVisible: Bool {
        playerManager.currentEpisode != nil
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                // Global refresh status banner
                if refreshManager.isRefreshing {
                    RefreshStatusBanner()
                }

                TabView {
                    LibraryView()
                        .tabItem {
                            Label("Library", systemImage: "books.vertical")
                        }

                    DownloadsView()
                        .tabItem {
                            Label("Downloads", systemImage: "arrow.down.circle")
                        }

                    StarredView()
                        .tabItem {
                            Label("Starred", systemImage: "star")
                        }

                    QueueView()
                        .tabItem {
                            Label("Queue", systemImage: "list.bullet")
                        }
                        .badge(queueItems.count)

                    SettingsView()
                        .tabItem {
                            Label("Settings", systemImage: "gear")
                        }
                }
                .tabViewStyle(.tabBarOnly)
            }
            .environment(\.miniPlayerVisible, isMiniPlayerVisible)

            if isMiniPlayerVisible {
                MiniPlayerView(showNowPlaying: $showNowPlaying)
                    .padding(.bottom, 57) // Tab bar height (49) + spacing (8)
                    .transition(.move(edge: .bottom))
            }

            // Offline indicator
            if !networkMonitor.isConnected {
                HStack(spacing: 4) {
                    Image(systemName: "wifi.slash")
                        .font(.caption2)
                    Text("Offline")
                        .font(.caption2)
                        .fontWeight(.medium)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(.ultraThinMaterial)
                .clipShape(Capsule())
                .padding(.bottom, isMiniPlayerVisible ? 105 : 55)
            }
        }
        .ignoresSafeArea(.keyboard)
        .animation(.default, value: isMiniPlayerVisible)
        .sheet(isPresented: $showNowPlaying) {
            NowPlayingView()
        }
    }
}

#Preview {
    ContentView()
}
