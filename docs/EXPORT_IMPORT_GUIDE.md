# Export & Import Guide

## Overview

The Export & Import feature lets you back up and restore Muninn data between devices, simulators, or fresh installs. Use it for device migration, manual backups, or recovering after reinstalling the app.

## What Gets Exported?

### Podcasts-Only Export
- Podcast feed URLs (subscriptions)

### Full Data Export
- **Podcasts**: All your podcast subscriptions with custom playback speeds
- **Folders**: Your folder organization with colors and podcast assignments
- **Playlists**: User-created episode playlists with order preserved
- **Episode States**:
  - Played/unplayed status
  - Starred episodes
  - Playback positions (where you left off)
- **Queue**: Your episode queue with order preserved
- **Settings**:
  - Global playback speed
  - Skip forward/backward intervals
  - Download preferences
  - Storage limits
  - Transcription settings
- **Statistics**: Summary of your library (for reference)

### What's NOT Exported
- **Downloaded episode files**: Re-download episodes after importing
- **Local transcripts and generated chapters**: Re-transcribe or regenerate after importing
- **Listening history/stats**: Only current episode states are exported
- **Image cache**: Artwork will be re-downloaded

## How to Use

### Exporting from Muninn

1. Open Muninn on your current device
2. Go to **Settings** → **Export & Import**
3. Choose your export type:
   - **Export Podcasts Only**: Quick export of just your subscriptions
   - **Export Full Data**: Complete backup of subscriptions, folders, playlists, queue, and episode state
4. The app creates a JSON file and shows the share sheet
5. Save the file to:
   - **iCloud Drive** (recommended for easy access on other devices)
   - **Files app**
   - **Email to yourself**
   - **AirDrop to another device**

### Importing into Muninn

1. Install Muninn on the target device
2. Make sure you have the export file accessible (in Files, iCloud Drive, etc.)
3. Open Muninn
4. Go to **Settings** → **Export & Import**
5. Tap **Import from File**
6. Select your export file
7. Wait for the import to complete (may take a few minutes for large libraries)
8. Your data will be restored

## Migration Workflow

Recommended workflow for moving Muninn to a new device:

1. **Before uninstalling on the old device**:
   - Open Muninn
   - Go to Settings → Export & Import
   - Tap "Export Full Data"
   - Save the file to iCloud Drive or email it to yourself
   - Verify the file was saved successfully

2. **Install Muninn on the new device**:
   - Open it (it will be empty initially)

3. **Import your data**:
   - In Muninn, go to Settings → Export & Import
   - Tap "Import from File"
   - Select your export file
   - Wait for import to complete

4. **Verify import**:
   - Check that your podcasts are all there
   - Verify folders and playlists are organized correctly
   - Check that starred episodes are marked
   - Confirm your queue is intact

5. **Re-download and re-process episodes** (if needed):
   - Import does not transfer downloaded audio, transcripts, or generated chapters
   - Re-download episodes you want offline
   - Re-run transcription/chapter generation if needed

6. **Uninstall old app** (optional):
   - Once you've verified everything works on the new device
   - Keep your export file as a backup

## File Format

Export files are JSON format with the following structure:

### Podcasts-Only Export
```json
{
  "version": 1,
  "exportDate": "2026-02-03T...",
  "appName": "Muninn",
  "podcasts": [
    {
      "feedURL": "https://..."
    }
  ]
}
```

### Full Data Export
```json
{
  "version": 1,
  "exportDate": "2026-02-03T...",
  "appName": "Muninn",
  "podcasts": [...],
  "folders": [...],
  "playlists": [...],
  "episodeStates": [...],
  "queue": [...],
  "settings": {...},
  "stats": {...}
}
```

## Troubleshooting

### Import Takes a Long Time
- This is normal for large libraries
- The app needs to fetch feed data for each podcast
- Be patient and keep the app open
- If you have 50+ podcasts, it may take 5–10 minutes

### Some Podcasts Failed to Import
- The app will show a message indicating how many succeeded/failed
- Failed podcasts are usually due to:
  - Feed URL no longer exists
  - Network issues
  - Feed temporarily unavailable
- You can manually re-add failed podcasts later

### Episode States Not Restored
- Make sure you used "Export Full Data" not "Podcasts Only"
- Episode states are matched by GUID
- If a podcast has been updated and episode GUIDs changed, states may not match
- Playback positions are restored when episodes are found

### Queue or Playlists Not Restored
- Queue and playlists are only exported in "Full Data" export
- Episodes must exist in your library for queue/playlist items to be restored
- If podcasts failed to import, their episodes won't be restored into playlists or queue

## Tips

1. **Export regularly**: Create backups periodically, not just when switching devices
2. **Test import on a second device first**: If possible, test the import before uninstalling the old app
3. **Keep export files**: Store export files in iCloud Drive or another backup location
4. **Use descriptive filenames**: The app generates timestamped filenames automatically
5. **Check file size**: Full exports can be several MB for large libraries — make sure you have space

## Privacy & Security

- Export files are stored locally on your device
- No data is sent to any servers
- Files are plain JSON — you can inspect them with any text editor
- Keep export files secure as they contain your podcast subscriptions and listening history
- Delete old export files when no longer needed

## Version Compatibility

- Export format version: 1
- Compatible with Muninn exports from current app versions
- Future versions will maintain backward compatibility where possible
- If the format changes, the version number will increment
