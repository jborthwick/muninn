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
    @State private var selectedTab = 0

    /// Index of the Settings tab in the TabView below
    private let settingsTabIndex = 4

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

                TabView(selection: $selectedTab) {
                    LibraryView()
                        .tabItem {
                            Label("Library", systemImage: "books.vertical")
                        }
                        .tag(0)

                    DownloadsView()
                        .tabItem {
                            Label("Downloads", systemImage: "arrow.down.circle")
                        }
                        .tag(1)

                    StarredView()
                        .tabItem {
                            Label("Starred", systemImage: "star")
                        }
                        .tag(2)

                    QueueView()
                        .tabItem {
                            Label("Queue", systemImage: "list.bullet")
                        }
                        .badge(queueItems.count)
                        .tag(3)

                    SettingsView()
                        .tabItem {
                            Label("Settings", systemImage: "gear")
                        }
                        .tag(4)
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
            // When simulate offline is active the badge is tappable and navigates to
            // Settings so the user can easily turn it off.
            if !networkMonitor.isConnected {
                let isSimulated = networkMonitor.simulateOffline
                Button {
                    if isSimulated {
                        selectedTab = settingsTabIndex
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "wifi.slash")
                            .font(.caption2)
                        Text(isSimulated ? "Simulated Offline — Tap to disable" : "Offline")
                            .font(.caption2)
                            .fontWeight(.medium)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(isSimulated ? AnyShapeStyle(Color.orange.opacity(0.85)) : AnyShapeStyle(.ultraThinMaterial))
                    .foregroundStyle(isSimulated ? .white : .primary)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .padding(.bottom, isMiniPlayerVisible ? 105 : 55)
                .animation(.default, value: isSimulated)
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
