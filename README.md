# Muninn

A personal iOS podcast player built with SwiftUI and SwiftData, focused on transcripts and AI-assisted understanding of audio content.

## Features

- **Podcast Management**: Subscribe to podcasts via RSS feed URL or search
- **Offline Playback**: Download episodes for offline listening with offline mode indicator
- **Folders**: Organize podcasts into color-coded folders
- **Queue**: Build a queue with "Play Next" and "Add to Queue", queue badge on tab, toggle queue membership, inline drag reorder with minus buttons
- **Starring**: Star episodes to save them for later
- **Sleep Timer**: Set a timer or stop at end of episode
- **Playback Speed**: Global speed (0.5x-3x) with per-podcast overrides, instant preview when selecting speed
- **Customizable Skip**: Configure skip forward/backward intervals (mini player includes skip backward button)
- **Audio Output**: Route audio to AirPods, speakers, or other devices via built-in picker
- **Smart Playback**: "Mark as Played" auto-advances to next queued episode, headphone reconnect pre-loads audio
- **Rich Episode Descriptions**: HTML descriptions with tappable links
- **Now Playing Indicator**: Currently playing episode shows play/pause button across all episode lists
- **Download Management**: Confirmation before deleting downloads, played/unplayed state indicators, throttled progress updates
- **iCloud Sync**: Sync subscriptions, folders, and listening progress across devices (requires paid Apple Developer account)
- **Listening Stats**: Track your listening habits

## Requirements

- iOS 18.0+
- Xcode 16+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)

## Setup

1. Install XcodeGen if you haven't:
   ```bash
   brew install xcodegen
   ```

2. Clone the repository:
   ```bash
   git clone https://github.com/jborthwick/muninn.git
   cd muninn
   ```

3. Generate the Xcode project:
   ```bash
   xcodegen generate
   ```

4. Open the project in Xcode:
   ```bash
   open muninn.xcodeproj
   ```

5. Select your Development Team in Xcode:
   - Select the Muninn target
   - Go to Signing & Capabilities
   - Select your team from the dropdown

6. Build and run on your device or simulator

### iCloud Sync (Optional)

iCloud sync requires a paid Apple Developer account. To enable it:

1. Add the iCloud capability in Xcode (Signing & Capabilities)
2. Enable "iCloud Documents" with container `iCloud.com.personal.muninn`
3. Create `Muninn/Muninn.entitlements` with the iCloud container identifiers

Without iCloud, the app works fully but sync is disabled.

## Architecture

- **SwiftUI** for the UI layer
- **SwiftData** for persistence
- **AVFoundation** for audio playback
- **iCloud Drive** for cross-device sync (no CloudKit required)

## Project Structure

```
Muninn/
├── Models/          # SwiftData models
├── Services/        # Business logic (AudioPlayer, Download, Sync, etc.)
├── Views/           # SwiftUI views organized by feature
│   ├── Library/
│   ├── Player/
│   ├── Podcast/
│   ├── Folders/
│   ├── Downloads/
│   ├── Starred/
│   ├── Queue/
│   └── Settings/
└── Extensions/      # Swift extensions
```

## License

MIT License - feel free to use this for your own podcast app!
