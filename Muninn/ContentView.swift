import SwiftUI
import SwiftData

// Preference key: PodcastDetailView bubbles up selection state so ContentView
// can hide the tab accessory while the action bar slides in.
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
    @Environment(\.scenePhase) private var scenePhase
    @Query(sort: \QueueItem.sortOrder) private var queueItems: [QueueItem]
    @State private var showNowPlaying = false
    @State private var selectedTab = 0
    @State private var episodeSelectionBarActive = false

    /// Index of the Settings tab in the TabView below
    private let settingsTabIndex = 3

    private var isMiniPlayerVisible: Bool {
        playerManager.currentEpisode != nil
    }

    /// Mini player is hidden while episode selection is active so the two pills
    /// don't overlap.
    private var effectiveMiniPlayerVisible: Bool {
        isMiniPlayerVisible && !episodeSelectionBarActive
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            TabView(selection: $selectedTab) {
                LibraryView()
                    .tabItem {
                        Label("Library", systemImage: "books.vertical")
                    }
                    .tag(0)

                PlaylistsView()
                    .tabItem {
                        Label("Playlists", systemImage: "music.note.list")
                    }
                    .tag(1)

                QueueView()
                    .tabItem {
                        Label("Queue", systemImage: "list.bullet")
                    }
                    .badge(queueItems.count)
                    .tag(2)

                SettingsView()
                    .tabItem {
                        Label("Settings", systemImage: "gear")
                    }
                    .tag(3)
            }
            .tabViewStyle(.tabBarOnly)
            .tabBarMinimizeBehavior(.onScrollDown)
            .tabViewBottomAccessory {
                if effectiveMiniPlayerVisible {
                    MiniPlayerView(showNowPlaying: $showNowPlaying)
                }
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
                .padding(.bottom, 8)
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
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                // Session is live — if we die now, next launch records an unclean exit.
                CrashReporter.shared.markLaunchInProgress()
            case .background:
                // Suspended/background kills are normal; don't treat them as crashes.
                CrashReporter.shared.markCleanExit()
            case .inactive:
                break
            @unknown default:
                break
            }
        }
    }
}

#Preview {
    ContentView()
}
