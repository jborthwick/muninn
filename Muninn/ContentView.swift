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

// Preference key: PodcastDetailView bubbles up selection state so ContentView
// can slide the mini player out while the action bar slides in.
struct EpisodeSelectionActivePreference: PreferenceKey {
    static var defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}

struct ContentView: View {
    private var playerManager = AudioPlayerManager.shared
    private var refreshManager = RefreshManager.shared
    private var networkMonitor = NetworkMonitor.shared
    @Query(sort: \QueueItem.sortOrder) private var queueItems: [QueueItem]
    @State private var showNowPlaying = false
    @State private var selectedTab = 0
    @State private var episodeSelectionBarActive = false

    /// Index of the Settings tab in the TabView below
    private let settingsTabIndex = 4

    private var isMiniPlayerVisible: Bool {
        playerManager.currentEpisode != nil
    }

    /// Mini player is hidden while episode selection is active so the two pills
    /// don't overlap. Views that inset scroll content use this value.
    private var effectiveMiniPlayerVisible: Bool {
        isMiniPlayerVisible && !episodeSelectionBarActive
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
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
            .environment(\.miniPlayerVisible, effectiveMiniPlayerVisible)

            // Mini player slides out when episode selection is active so it
            // doesn't sit behind the selection action bar.
            if effectiveMiniPlayerVisible {
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
                .padding(.bottom, effectiveMiniPlayerVisible ? 105 : 55)
                .animation(.default, value: isSimulated)
            }
        }
        .ignoresSafeArea(.keyboard)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: episodeSelectionBarActive)
        .animation(.default, value: isMiniPlayerVisible)
        .onPreferenceChange(EpisodeSelectionActivePreference.self) { active in
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                episodeSelectionBarActive = active
            }
        }
        .sheet(isPresented: $showNowPlaying) {
            NowPlayingView()
        }
    }
}

#Preview {
    ContentView()
}
