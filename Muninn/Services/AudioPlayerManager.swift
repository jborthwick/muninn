import AVFoundation
import MediaPlayer
import SwiftUI
import SwiftData
import Combine
import os

/// Singleton manager for audio playback
@MainActor
@Observable
final class AudioPlayerManager {
    static let shared = AudioPlayerManager()

    private let logger = AppLogger.audio

    // MARK: - UserDefaults Keys

    private enum Keys {
        static let playbackSpeed = "playbackSpeed"
        static let skipForwardInterval = "skipForwardInterval"
        static let skipBackwardInterval = "skipBackwardInterval"
        static let lastEpisodeGuid = "lastEpisodeGuid"
        static let lastPlaybackPosition = "lastPlaybackPosition"
    }

    // MARK: - Observable State

    private(set) var currentEpisode: Episode?
    private(set) var isPlaying = false
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var isLoading = false
    // Global default speed (saved to UserDefaults)
    var globalPlaybackSpeed: Double {
        didSet {
            UserDefaults.standard.set(globalPlaybackSpeed, forKey: Keys.playbackSpeed)
            // Update current playback if no per-podcast override
            if currentEpisode?.podcast?.playbackSpeedOverride == nil {
                player?.rate = isPlaying ? Float(globalPlaybackSpeed) : 0
                updateNowPlayingInfo()
            }
        }
    }

    // Effective speed for current episode (uses per-podcast override if set)
    var effectivePlaybackSpeed: Double {
        currentEpisode?.podcast?.playbackSpeedOverride ?? globalPlaybackSpeed
    }

    // Legacy property for compatibility - sets global speed
    var playbackSpeed: Double {
        get { effectivePlaybackSpeed }
        set {
            // If current podcast has override, update that; otherwise update global
            if let podcast = currentEpisode?.podcast, podcast.playbackSpeedOverride != nil {
                podcast.playbackSpeedOverride = newValue
                player?.rate = isPlaying ? Float(newValue) : 0
                updateNowPlayingInfo()
            } else {
                globalPlaybackSpeed = newValue
            }
        }
    }

    // Skip intervals (customizable)
    var skipForwardInterval: TimeInterval {
        didSet {
            UserDefaults.standard.set(skipForwardInterval, forKey: Keys.skipForwardInterval)
            updateRemoteCommandIntervals()
        }
    }
    var skipBackwardInterval: TimeInterval {
        didSet {
            UserDefaults.standard.set(skipBackwardInterval, forKey: Keys.skipBackwardInterval)
            updateRemoteCommandIntervals()
        }
    }

    // Sleep timer
    private(set) var sleepTimerEndTime: Date?
    private var sleepTimer: Timer?

    // MARK: - Private Properties

    private var player: AVPlayer?
    private var timeObserverTask: Task<Void, Never>?
    private var statusObserver: NSKeyValueObservation?
    private var didFinishObserver: NSObjectProtocol?
    private var cachedArtwork: MPMediaItemArtwork?
    private var cachedArtworkURL: String?

    // MARK: - Initialization

    private init() {
        // Load saved playback speed
        let savedSpeed = UserDefaults.standard.double(forKey: Keys.playbackSpeed)
        self.globalPlaybackSpeed = savedSpeed > 0 ? savedSpeed : 1.0

        // Load saved skip intervals
        let savedSkipForward = UserDefaults.standard.double(forKey: Keys.skipForwardInterval)
        self.skipForwardInterval = savedSkipForward > 0 ? savedSkipForward : 30

        let savedSkipBackward = UserDefaults.standard.double(forKey: Keys.skipBackwardInterval)
        self.skipBackwardInterval = savedSkipBackward > 0 ? savedSkipBackward : 15

        setupAudioSession()
        setupRemoteCommands()
        setupAppLifecycleObservers()
    }

    private func setupAppLifecycleObservers() {
        // Save state when app goes to background
        NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.saveLastEpisode()
            }
        }

        // Save state when app is terminating
        NotificationCenter.default.addObserver(
            forName: UIApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.saveCurrentPosition()
            }
        }
    }

    // Note: deinit not needed as this is a singleton that lives for app lifetime.
    // Sleep timer and observers are cleaned up in their respective methods.

    // MARK: - Public Methods

    func play(_ episode: Episode) {
        // Validate episode has audio URL
        guard !episode.audioURL.isEmpty else {
            logger.error("Cannot play episode: empty audio URL")
            return
        }

        // Determine URL first (validate before changing state)
        let url: URL
        if let fileURL = episode.localFileURL {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                url = fileURL
                logger.info("Playing from local file: \(fileURL.path)")
            } else {
                // Local path set but file doesn't exist - try remote if online
                logger.warning("Local file not found at: \(fileURL.path)")
                if !NetworkMonitor.shared.isConnected {
                    // Offline and file missing - can't play
                    logger.warning("Cannot play: offline and local file missing")
                    return
                }
                guard let remoteURL = URL(string: episode.audioURL) else {
                    logger.error("Cannot play: invalid audio URL: \(episode.audioURL)")
                    return
                }
                url = remoteURL
                logger.info("Falling back to remote URL: \(remoteURL)")
            }
        } else {
            // No local file - need network
            if !NetworkMonitor.shared.isConnected {
                logger.warning("Cannot play: offline and no local file")
                return
            }
            guard let remoteURL = URL(string: episode.audioURL) else {
                logger.error("Cannot play: invalid audio URL: \(episode.audioURL)")
                return
            }
            url = remoteURL
            logger.info("Playing from remote URL: \(remoteURL)")
        }

        // URL is valid - now stop old playback and switch
        saveCurrentPosition()
        clearObservers()
        player?.pause()
        player = nil

        // End previous listening session and start new one
        StatsService.shared.startListening(episode: episode)

        currentEpisode = episode
        isLoading = true

        // Activate audio session when starting playback
        activateAudioSession()

        // Create player
        let playerItem = AVPlayerItem(url: url)
        player = AVPlayer(playerItem: playerItem)

        // Observe status
        statusObserver = playerItem.observe(\.status, options: [.new]) { [weak self] item, _ in
            DispatchQueue.main.async {
                self?.handleStatusChange(item.status, for: item)
            }
        }

        // Observe playback finished
        didFinishObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handlePlaybackEnded()
            }
        }

        setupTimeObserver()
    }

    private func handleStatusChange(_ status: AVPlayerItem.Status, for item: AVPlayerItem) {
        switch status {
        case .readyToPlay:
            isLoading = false
            
            // Safely extract duration
            let itemDuration = item.duration.seconds
            duration = (itemDuration.isNaN || itemDuration.isInfinite) ? 0 : itemDuration

            // Seek to saved position
            if let episode = currentEpisode, episode.playbackPosition > 0 {
                // Validate position is within bounds
                let validPosition = min(episode.playbackPosition, max(duration - 1, 0))
                if validPosition > 0 {
                    seek(to: validPosition)
                }
            }

            resume()
            updateNowPlayingInfo()
        case .failed:
            isLoading = false
            let errorMessage = item.error?.localizedDescription ?? "unknown error"
            logger.error("Playback failed: \(errorMessage)")
            
            // Clear player state on failure
            clearObservers()
            player = nil
            currentEpisode = nil
            isPlaying = false
        default:
            break
        }
    }

    func resume() {
        // If we have an episode but no player, need to reload
        if currentEpisode != nil && player == nil {
            if let episode = currentEpisode {
                play(episode)
            }
            return
        }

        // Re-activate audio session — some headphones need this after pause
        activateAudioSession()

        player?.rate = Float(effectivePlaybackSpeed)
        isPlaying = true
        updateNowPlayingInfo()
        StatsService.shared.resumeListening()
    }

    /// Marks the current episode as played, posts completion notification,
    /// cleans up the player, and advances to the next queue item.
    func markPlayedAndAdvance() {
        guard let episode = currentEpisode else { return }
        episode.isPlayed = true
        episode.playbackPosition = 0

        // Notify for download cleanup
        NotificationCenter.default.post(
            name: .episodePlaybackCompleted,
            object: nil,
            userInfo: ["guid": episode.guid]
        )

        StatsService.shared.endCurrentSession()
        clearObservers()
        player?.pause()
        player = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        clearNowPlayingInfo()

        // Auto-advance to next queue item
        if let nextEpisode = QueueManager.shared.popNextEpisode() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.play(nextEpisode)
            }
        } else {
            currentEpisode = nil
            deactivateAudioSession()
        }
    }

    /// Immediately sets the player rate for speed preview (without saving)
    func previewSpeed(_ speed: Double) {
        guard let player = player, isPlaying else { return }
        player.rate = Float(speed)
    }

    func pause() {
        player?.pause()
        isPlaying = false
        saveCurrentPosition()
        updateNowPlayingInfo()
        StatsService.shared.pauseListening()
    }

    func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            resume()
        }
    }

    func seek(to time: TimeInterval) {
        // Validate time is not NaN or infinite
        guard !time.isNaN && !time.isInfinite && time >= 0 else {
            logger.warning("Invalid seek time: \(time)")
            return
        }
        
        // Clamp to valid range
        let validTime = min(max(time, 0), duration)
        
        let cmTime = CMTime(seconds: validTime, preferredTimescale: 600)
        player?.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = validTime
        updateNowPlayingInfo()
    }

    func skipForward(_ seconds: TimeInterval? = nil) {
        let interval = seconds ?? skipForwardInterval
        let newTime = min(currentTime + interval, duration)
        seek(to: newTime)
    }

    func skipBackward(_ seconds: TimeInterval? = nil) {
        let interval = seconds ?? skipBackwardInterval
        let newTime = max(currentTime - interval, 0)
        seek(to: newTime)
    }

    // MARK: - Sleep Timer

    var sleepTimerRemaining: TimeInterval? {
        guard let endTime = sleepTimerEndTime else { return nil }
        let remaining = endTime.timeIntervalSinceNow
        return remaining > 0 ? remaining : nil
    }

    func setSleepTimer(minutes: Int) {
        cancelSleepTimer()

        if minutes <= 0 { return }

        sleepTimerEndTime = Date().addingTimeInterval(TimeInterval(minutes * 60))

        sleepTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let remaining = self.sleepTimerRemaining, remaining <= 0 {
                    self.pause()
                    self.cancelSleepTimer()
                }
            }
        }
    }

    func setSleepTimerEndOfEpisode() {
        cancelSleepTimer()

        // Set a sentinel value - we'll check this in handlePlaybackEnded
        sleepTimerEndTime = Date.distantFuture
    }

    func cancelSleepTimer() {
        sleepTimer?.invalidate()
        sleepTimer = nil
        sleepTimerEndTime = nil
    }

    var isSleepTimerEndOfEpisode: Bool {
        sleepTimerEndTime == Date.distantFuture
    }

    func stop() {
        saveCurrentPosition()
        saveLastEpisode()  // Save before clearing so it can be restored later
        StatsService.shared.endCurrentSession()
        clearObservers()
        player?.pause()
        player = nil
        currentEpisode = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        clearNowPlayingInfo()
        deactivateAudioSession()
    }

    // MARK: - Audio Session

    private func setupAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            // Only set category at init - don't activate until playback
            try session.setCategory(.playback, mode: .spokenAudio, options: [])
        } catch {
            logger.error("Failed to setup audio session: \(error)")
        }

        // Handle interruptions (phone calls, etc.)
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in
                self?.handleInterruption(notification)
            }
        }

        // Handle route changes (headphones unplugged)
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in
                self?.handleRouteChange(notification)
            }
        }
    }

    private func activateAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setActive(true, options: [])
        } catch {
            logger.error("Failed to activate audio session: \(error)")
        }
    }

    private func deactivateAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        } catch {
            logger.error("Failed to deactivate audio session: \(error)")
        }
    }

    private func handleInterruption(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }

        switch type {
        case .began:
            // Interruption began - pause playback
            pause()
        case .ended:
            // Interruption ended - resume if appropriate
            if let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt {
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                if options.contains(.shouldResume) {
                    resume()
                }
            }
        @unknown default:
            break
        }
    }

    private func handleRouteChange(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else {
            return
        }

        switch reason {
        case .oldDeviceUnavailable:
            // Pause when headphones are unplugged
            pause()
        case .newDeviceAvailable:
            // When AirPods reconnect, pre-activate audio session and
            // pre-load player item from local file to reduce playback delay
            if let episode = currentEpisode {
                activateAudioSession()
                // Pre-load player if not already loaded
                if player == nil || player?.currentItem == nil {
                    if let fileURL = episode.localFileURL,
                       FileManager.default.fileExists(atPath: fileURL.path) {
                        let playerItem = AVPlayerItem(url: fileURL)
                        player = AVPlayer(playerItem: playerItem)
                        setupTimeObserver()
                    }
                }
                updateNowPlayingInfo()
            }
        default:
            break
        }
    }

    // MARK: - Time Observer

    private func setupTimeObserver() {
        timeObserverTask?.cancel()
        // Poll player.currentTime() on a plain async loop instead of addPeriodicTimeObserver.
        // This avoids CoreAudio AudioDeviceGetCurrentTime calls that flood the simulator console.
        timeObserverTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                if let self, let player = self.player {
                    let newTime = player.currentTime().seconds
                    if !newTime.isNaN && !newTime.isInfinite && newTime >= 0 {
                        self.currentTime = newTime
                    }
                }
                try? await Task.sleep(for: .seconds(0.5))
            }
        }
    }

    private func clearObservers() {
        timeObserverTask?.cancel()
        timeObserverTask = nil
        statusObserver?.invalidate()
        statusObserver = nil
        if let observer = didFinishObserver {
            NotificationCenter.default.removeObserver(observer)
            didFinishObserver = nil
        }
    }

    // MARK: - Remote Commands (Lock Screen)

    private func setupRemoteCommands() {
        let commandCenter = MPRemoteCommandCenter.shared()

        commandCenter.playCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async {
                self?.resume()
            }
            return .success
        }

        commandCenter.pauseCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async {
                self?.pause()
            }
            return .success
        }

        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async {
                self?.togglePlayPause()
            }
            return .success
        }

        commandCenter.skipForwardCommand.preferredIntervals = [NSNumber(value: skipForwardInterval)]
        commandCenter.skipForwardCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async {
                self?.skipForward()
            }
            return .success
        }

        commandCenter.skipBackwardCommand.preferredIntervals = [NSNumber(value: skipBackwardInterval)]
        commandCenter.skipBackwardCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async {
                self?.skipBackward()
            }
            return .success
        }

        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            DispatchQueue.main.async {
                self?.seek(to: event.positionTime)
            }
            return .success
        }
    }

    private func updateRemoteCommandIntervals() {
        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.skipForwardCommand.preferredIntervals = [NSNumber(value: skipForwardInterval)]
        commandCenter.skipBackwardCommand.preferredIntervals = [NSNumber(value: skipBackwardInterval)]
    }

    // MARK: - Now Playing Info

    private func updateNowPlayingInfo() {
        guard let episode = currentEpisode else { return }

        var info = [String: Any]()
        info[MPMediaItemPropertyTitle] = episode.title
        info[MPMediaItemPropertyArtist] = episode.podcast?.title ?? ""
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPMediaItemPropertyPlaybackDuration] = duration
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? effectivePlaybackSpeed : 0

        // Use cached artwork if available
        if let cachedArtwork = cachedArtwork {
            info[MPMediaItemPropertyArtwork] = cachedArtwork
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info

        // Load artwork asynchronously only if not cached or URL changed
        let artworkURLString = episode.displayArtworkURL
        if cachedArtwork == nil || cachedArtworkURL != artworkURLString {
            if let artworkURLString = artworkURLString,
               let artworkURL = URL(string: artworkURLString) {
                Task { [weak self] in
                    guard let self else { return }
                    if let (data, _) = try? await URLSession.shared.data(from: artworkURL),
                       let image = UIImage(data: data) {
                        let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                        self.cachedArtwork = artwork
                        self.cachedArtworkURL = artworkURLString

                        var updatedInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
                        updatedInfo[MPMediaItemPropertyArtwork] = artwork
                        MPNowPlayingInfoCenter.default().nowPlayingInfo = updatedInfo
                    }
                }
            }
        }
    }

    private func clearNowPlayingInfo() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        cachedArtwork = nil
        cachedArtworkURL = nil
    }

    // MARK: - Position Saving

    private func saveCurrentPosition() {
        guard let episode = currentEpisode, currentTime > 0 else { return }
        episode.playbackPosition = currentTime

        // Mark as played if near the end (within 30 seconds)
        if duration > 0 && currentTime >= duration - 30 {
            episode.isPlayed = true
            episode.playbackPosition = 0
        }

        // Save last episode GUID for restoration on next launch
        saveLastEpisode()
    }

    private func saveLastEpisode() {
        guard let episode = currentEpisode else {
            // Clear saved episode if nothing playing
            UserDefaults.standard.removeObject(forKey: Keys.lastEpisodeGuid)
            UserDefaults.standard.removeObject(forKey: Keys.lastPlaybackPosition)
            return
        }
        UserDefaults.standard.set(episode.guid, forKey: Keys.lastEpisodeGuid)
        UserDefaults.standard.set(currentTime, forKey: Keys.lastPlaybackPosition)
    }

    /// Restores the last played episode on app launch (without starting playback)
    func restoreLastEpisode(from context: SwiftData.ModelContext) {
        guard currentEpisode == nil,
              let guid = UserDefaults.standard.string(forKey: Keys.lastEpisodeGuid) else {
            return
        }

        // Fetch the episode by GUID
        let predicate = #Predicate<Episode> { $0.guid == guid }
        let descriptor = FetchDescriptor<Episode>(predicate: predicate)

        guard let episodes = try? context.fetch(descriptor),
              let episode = episodes.first else {
            // Episode not found - clear saved state
            UserDefaults.standard.removeObject(forKey: Keys.lastEpisodeGuid)
            UserDefaults.standard.removeObject(forKey: Keys.lastPlaybackPosition)
            return
        }

        // Restore episode state (without playing)
        currentEpisode = episode

        // Restore position from either UserDefaults or episode's saved position
        let savedPosition = UserDefaults.standard.double(forKey: Keys.lastPlaybackPosition)
        currentTime = savedPosition > 0 ? savedPosition : episode.playbackPosition

        // Get duration from episode if available
        duration = episode.duration ?? 0

        // Update Now Playing info so lock screen shows the episode
        updateNowPlayingInfo()

        logger.info("Restored last episode: \(episode.title)")
    }

    // MARK: - Playback Ended

    private func handlePlaybackEnded() {
        guard let episode = currentEpisode else { return }
        episode.isPlayed = true
        episode.playbackPosition = 0
        isPlaying = false

        // Notify for download cleanup
        NotificationCenter.default.post(
            name: .episodePlaybackCompleted,
            object: nil,
            userInfo: ["guid": episode.guid]
        )

        // Check if sleep timer is set to end of episode
        if isSleepTimerEndOfEpisode {
            cancelSleepTimer()
            // Don't auto-advance - just stop
            clearObservers()
            player = nil
            currentEpisode = nil
            currentTime = 0
            duration = 0
            clearNowPlayingInfo()
            deactivateAudioSession()
            return
        }

        // Auto-advance to next queue item
        if let nextEpisode = QueueManager.shared.popNextEpisode() {
            // Small delay before playing next
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.play(nextEpisode)
            }
        } else {
            // No more items in queue - clear player
            clearObservers()
            player = nil
            currentEpisode = nil
            currentTime = 0
            duration = 0
            clearNowPlayingInfo()
            deactivateAudioSession()
        }
    }
}
