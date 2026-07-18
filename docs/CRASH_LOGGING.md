# Crash Logging System

## Overview
Muninn records crash and diagnostic reports locally so they can be reviewed in
**Settings → Debug → Crash Logs**.

## What Gets Captured

| Source | When it appears | Stack trace? |
|---|---|---|
| **MetricKit crash/hang/CPU** | Next app launch after the event | Yes (JSON call stack tree) |
| **Fatal signals** (SIGABRT/SEGV/BUS/ILL/TRAP) | Next launch (breadcrumb) + system crash report | Limited in-app; prefer MetricKit |
| **Objective-C `NSException`** | Same process, just before death | Yes |
| **Unclean exit** | Next launch if the previous foreground session never reached background | No — marker only |
| **`logCritical(...)`** | Immediately | Yes |

### What usually does *not* appear
- Crashes while the app is attached to the Xcode debugger (Xcode intercepts them)
- Pure Swift `fatalError` / traps if the process is killed before handlers run — MetricKit usually still delivers on next launch
- Force-quit from the app switcher after the app was already backgrounded (that is a clean path)

## How to Use

1. Open **Settings → Debug → Crash Logs**
2. After a crash, **relaunch the app** — MetricKit reports are delivered on the next launch
3. Open a report to view/share it

## Storage
- Directory: `Documents/CrashLogs/`
- Files: `crash-<type>-<timestamp>.txt`
- Local only — never uploaded automatically

## Implementation
- `Muninn/Services/CrashReporter.swift` — handlers + MetricKit subscriber
- Installed in `MuninnApp.init()` before other launch work
- Clean/unclean session tracking via `scenePhase` in `ContentView`

## Alternative Debugging
- **Xcode** while debugging (best stacks for debugger-attached runs)
- **Xcode Organizer → Crashes** for TestFlight/device reports
- **Console.app** filtered by `com.personal.muninn`
- **Settings → Privacy → Analytics → Analytics Data** on device
