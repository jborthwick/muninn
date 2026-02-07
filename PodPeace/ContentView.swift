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
    @Environment(\.modelContext) private var modelContext
    private var playerManager = AudioPlayerManager.shared
    private var refreshManager = RefreshManager.shared
    private var networkMonitor = NetworkMonitor.shared
    @Query(sort: \QueueItem.sortOrder) private var queueItems: [QueueItem]
    @State private var showNowPlaying = false
    @State private var selectedTab: Int = 0

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
                .onAppear {
                    // Restore last selected tab
                    let settings = AppSettings.getOrCreate(context: modelContext)
                    selectedTab = settings.selectedTab
                }
                .onChange(of: selectedTab) { oldValue, newValue in
                    // Save selected tab asynchronously to avoid blocking tab switch animation
                    Task {
                        let settings = AppSettings.getOrCreate(context: modelContext)
                        settings.selectedTab = newValue
                        try? modelContext.save()
                    }
                }
            }
            .environment(\.miniPlayerVisible, isMiniPlayerVisible)

            if isMiniPlayerVisible {
                MiniPlayerView(showNowPlaying: $showNowPlaying)
                    .padding(.bottom, 49) // Standard tab bar height
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
