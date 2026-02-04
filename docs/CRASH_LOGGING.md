# Crash Logging System

## Overview
A comprehensive crash logging system has been added to Podcash to help diagnose and debug crashes.

## Files Added

### 1. `Podcash/Services/CrashReporter.swift`
- Captures uncaught exceptions and critical errors
- Saves crash reports to local storage
- Provides convenience functions for logging

### 2. `Podcash/Views/Settings/CrashLogsView.swift`
- UI for viewing crash logs within the app
- Accessible from Settings → Debug → Crash Logs
- Allows viewing, sharing, and deleting crash reports

## How to Use

### Viewing Crash Logs in the App
1. Open the app
2. Go to **Settings** tab
3. Scroll to **Debug** section
4. Tap **Crash Logs**
5. View, share, or delete crash reports

### Automatic Crash Capture
The system automatically captures:
- **Uncaught Exceptions**: Any Objective-C exceptions that would crash the app
- **Critical Errors**: Logged with `logCritical("message")`
- **Regular Errors**: Logged with `logError("message", error: error)`

### Manual Logging
You can manually log errors anywhere in the code:

```swift
// Log a critical error
logCritical("Something went very wrong!")

// Log a regular error
logError("Failed to load data", error: someError)

// Or use the shared instance
CrashReporter.shared.logCriticalError("Critical issue detected")
```

### Crash Report Format
Each crash report includes:
- **Type**: Exception, CriticalError, etc.
- **Name**: Location or exception name
- **Timestamp**: When the crash occurred
- **Reason**: Description of what went wrong
- **Stack Trace**: Full call stack for debugging

### Crash Report Storage
- Reports are saved in: `Documents/CrashLogs/`
- Named with timestamp: `crash-2024-02-03T15:30:00Z.txt`
- Persist between app launches
- Can be accessed via Files app or iTunes File Sharing

## Alternative Debugging Methods

### Console.app (Recommended for Development)
1. Connect iPhone to Mac
2. Open Console.app (`/Applications/Utilities/Console.app`)
3. Select your iPhone from sidebar
4. Filter by "Podcash"
5. Run app and watch for crashes in real-time

### Xcode Organizer
1. Open Xcode
2. Window → Organizer (⌘⇧2)
3. Click **Crashes** tab
4. Select your device
5. View crash reports with symbolicated stack traces

### Device Analytics
1. Settings → Privacy & Security → Analytics & Improvements → Analytics Data
2. Look for files starting with "Podcash"
3. Tap to view, share to export

## Implementation Details

### Initialization
The crash reporter is initialized in `PodcashApp.swift` on app launch:

```swift
.onAppear {
    // Initialize crash reporter (must be first)
    _ = CrashReporter.shared
    // ... other initialization
}
```

### Exception Handler
Uses `NSSetUncaughtExceptionHandler` to catch Objective-C exceptions before they crash the app.

### Thread Safety
All crash report writing is thread-safe and won't interfere with app performance.

## Tips for Debugging

1. **Check crash logs immediately after a crash** - The stack trace will show exactly where the crash occurred
2. **Look for patterns** - Multiple crashes in the same location indicate a specific issue
3. **Share crash reports** - Use the share button to send reports via email or Messages
4. **Use Console.app during development** - Provides the most detailed real-time information
5. **Keep crash logs enabled in production** - Helps diagnose issues that only occur in specific scenarios

## Privacy Note
Crash logs are stored locally on the device and are never automatically transmitted. Users must manually share them if they want to report issues.
