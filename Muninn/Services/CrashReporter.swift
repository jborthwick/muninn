import Foundation
import MetricKit
import os

/// Captures crashes and persists reports for Settings → Crash Logs.
///
/// Coverage:
/// - MetricKit crash/hang/CPU diagnostics (delivered on the *next* launch)
/// - Uncaught Objective-C `NSException`s
/// - Fatal Unix signals (SIGABRT/SEGV/BUS/ILL/TRAP) via a signal-safe write
/// - Unclean termination marker (watchdog/jetsam/force-quit mid-work — no stack)
///
/// Not covered: debugger-intercepted crashes while attached to Xcode (those often
/// never reach in-process handlers; use Xcode’s crash reporter instead).
final class CrashReporter: NSObject, MXMetricManagerSubscriber {
    static let shared = CrashReporter()
    private let logger = Logger(subsystem: "com.personal.muninn", category: "crash")

    private static let cleanExitKey = "CrashReporter.cleanExit"
    private static let signalLogFileName = "pending-signal-crash.txt"

    /// POSIX path used from signal handlers (must remain valid for process lifetime).
    fileprivate static var signalLogPathCString: UnsafeMutablePointer<CChar>?

    private override init() {
        super.init()
        Self.prepareCrashLogDirectory()
        setupExceptionHandler()
        setupSignalHandlers()
        MXMetricManager.shared.add(self)
        ingestPendingSignalLogIfNeeded()
        recordUncleanExitIfNeeded()
        markLaunchInProgress()
        ingestPastMetricKitDiagnostics()
    }

    deinit {
        MXMetricManager.shared.remove(self)
    }

    // MARK: - App Lifecycle

    /// Call from `scenePhase` / resign-active so a clean quit isn't treated as a crash.
    func markCleanExit() {
        UserDefaults.standard.set(true, forKey: Self.cleanExitKey)
    }

    /// Call on becoming active / launch so a subsequent kill is detectable.
    func markLaunchInProgress() {
        UserDefaults.standard.set(false, forKey: Self.cleanExitKey)
    }

    // MARK: - MXMetricManagerSubscriber

    func didReceive(_ payloads: [MXMetricPayload]) {
        // Daily metrics — not stored in Crash Logs.
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            persistMetricKitDiagnostics(payload)
        }
    }

    // MARK: - Manual Logging

    /// Logs a critical error that might lead to a crash
    func logCriticalError(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        let fileName = (file as NSString).lastPathComponent
        logger.critical("💥 CRITICAL ERROR at \(fileName):\(line) in \(function)")
        logger.critical("\(message)")

        saveCrashReport(
            type: "CriticalError",
            name: "\(fileName):\(line)",
            reason: message,
            stackTrace: Thread.callStackSymbols
        )
    }

    /// Logs a non-fatal error for debugging
    func logError(_ message: String, error: Error? = nil, file: String = #file, function: String = #function, line: Int = #line) {
        let fileName = (file as NSString).lastPathComponent
        logger.error("❌ ERROR at \(fileName):\(line) in \(function)")
        logger.error("\(message)")
        if let error = error {
            logger.error("Error details: \(error.localizedDescription)")
        }
    }

    // MARK: - Report Storage

    /// Returns all saved crash reports
    func getCrashReports() -> [URL] {
        guard let crashLogPath = Self.crashLogsDirectory() else { return [] }

        guard let files = try? FileManager.default.contentsOfDirectory(
            at: crashLogPath,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return files
            .filter { $0.pathExtension == "txt" && $0.lastPathComponent != Self.signalLogFileName }
            .sorted { url1, url2 in
                let date1 = (try? url1.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
                let date2 = (try? url2.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
                return date1 > date2
            }
    }

    /// Deletes all crash reports
    func clearCrashReports() {
        guard let crashLogPath = Self.crashLogsDirectory() else { return }
        try? FileManager.default.removeItem(at: crashLogPath)
        Self.prepareCrashLogDirectory()
    }

    // MARK: - Private Setup

    private func setupExceptionHandler() {
        NSSetUncaughtExceptionHandler { exception in
            let logger = Logger(subsystem: "com.personal.muninn", category: "crash")
            logger.critical("💥 UNCAUGHT EXCEPTION: \(exception.name.rawValue)")
            logger.critical("Reason: \(exception.reason ?? "unknown")")
            logger.critical("Stack trace: \(exception.callStackSymbols.joined(separator: "\n"))")

            CrashReporter.shared.saveCrashReport(
                type: "Exception",
                name: exception.name.rawValue,
                reason: exception.reason ?? "unknown",
                stackTrace: exception.callStackSymbols
            )
        }
    }

    private func setupSignalHandlers() {
        let signals: [Int32] = [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGFPE]
        for sig in signals {
            signal(sig, crashSignalHandler)
        }
    }

    private func ingestPastMetricKitDiagnostics() {
        for payload in MXMetricManager.shared.pastDiagnosticPayloads {
            persistMetricKitDiagnostics(payload)
        }
    }

    private func persistMetricKitDiagnostics(_ payload: MXDiagnosticPayload) {
        let stamp = payload.timeStampEnd

        if let crashes = payload.crashDiagnostics {
            for (index, crash) in crashes.enumerated() {
                let exceptionType = crash.exceptionType.map(String.init(describing:)) ?? "unknown"
                let exceptionCode = crash.exceptionCode.map(String.init(describing:)) ?? "unknown"
                let signalName = crash.signal.map(String.init(describing:)) ?? "unknown"
                let stack = String(data: crash.callStackTree.jsonRepresentation(), encoding: .utf8)
                    ?? "(call stack unavailable)"

                saveCrashReport(
                    type: "MetricKitCrash",
                    name: "exception \(exceptionType) / \(exceptionCode)",
                    reason: "signal \(signalName)",
                    stackTrace: stack.components(separatedBy: "\n"),
                    timestamp: stamp.addingTimeInterval(TimeInterval(index) * 0.001)
                )
            }
        }

        if let hangs = payload.hangDiagnostics {
            for (index, hang) in hangs.enumerated() {
                let stack = String(data: hang.callStackTree.jsonRepresentation(), encoding: .utf8)
                    ?? "(call stack unavailable)"
                saveCrashReport(
                    type: "MetricKitHang",
                    name: "hang",
                    reason: "duration \(hang.hangDuration)",
                    stackTrace: stack.components(separatedBy: "\n"),
                    timestamp: stamp.addingTimeInterval(TimeInterval(index + 100) * 0.001)
                )
            }
        }

        if let cpu = payload.cpuExceptionDiagnostics {
            for (index, diagnostic) in cpu.enumerated() {
                let stack = String(data: diagnostic.callStackTree.jsonRepresentation(), encoding: .utf8)
                    ?? "(call stack unavailable)"
                saveCrashReport(
                    type: "MetricKitCPUException",
                    name: "cpu exception",
                    reason: "totalCPUTime \(diagnostic.totalCPUTime), totalSampledTime \(diagnostic.totalSampledTime)",
                    stackTrace: stack.components(separatedBy: "\n"),
                    timestamp: stamp.addingTimeInterval(TimeInterval(index + 200) * 0.001)
                )
            }
        }
    }

    private func recordUncleanExitIfNeeded() {
        let defaults = UserDefaults.standard
        // Missing key → first launch after install; don't treat as a crash.
        guard defaults.object(forKey: Self.cleanExitKey) != nil else { return }
        guard defaults.bool(forKey: Self.cleanExitKey) == false else { return }

        saveCrashReport(
            type: "UncleanExit",
            name: "Previous launch did not exit cleanly",
            reason: """
            The previous session ended without a clean shutdown. Common causes: \
            native crash, watchdog kill, memory jetsam, or force-quit while work was in progress. \
            If a MetricKit crash report also appears, prefer that for the stack trace.
            """,
            stackTrace: ["(no in-process stack — process was already gone)"]
        )
    }

    private func ingestPendingSignalLogIfNeeded() {
        guard let dir = Self.crashLogsDirectory() else { return }
        let pending = dir.appendingPathComponent(Self.signalLogFileName)
        guard let data = try? Data(contentsOf: pending),
              let text = String(data: data, encoding: .utf8),
              !text.isEmpty else { return }

        saveCrashReport(
            type: "Signal",
            name: "Fatal signal",
            reason: text.trimmingCharacters(in: .whitespacesAndNewlines),
            stackTrace: ["(signal handler — limited stack; see MetricKit report if available)"]
        )
        try? FileManager.default.removeItem(at: pending)
    }

    /// Saves crash report to file
    private func saveCrashReport(
        type: String,
        name: String,
        reason: String,
        stackTrace: [String],
        timestamp: Date = Date()
    ) {
        let stamp = ISO8601DateFormatter().string(from: timestamp)

        let report = """
        ==========================================
        MUNINN CRASH REPORT
        ==========================================
        Type: \(type)
        Name: \(name)
        Time: \(stamp)
        Reason: \(reason)

        Stack Trace:
        \(stackTrace.joined(separator: "\n"))
        ==========================================
        """

        guard let crashLogPath = Self.crashLogsDirectory() else { return }

        let safeStamp = stamp.replacingOccurrences(of: ":", with: "-")
        let fileName = "crash-\(type)-\(safeStamp).txt"
        let filePath = crashLogPath.appendingPathComponent(fileName)

        // Avoid duplicate MetricKit deliveries creating identical files.
        if FileManager.default.fileExists(atPath: filePath.path) { return }

        do {
            try report.write(to: filePath, atomically: true, encoding: .utf8)
            logger.info("Crash report saved to: \(filePath.path)")
        } catch {
            logger.error("Failed to save crash report: \(error.localizedDescription)")
        }
    }

    private static func crashLogsDirectory() -> URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("CrashLogs", isDirectory: true)
    }

    private static func prepareCrashLogDirectory() {
        guard let dir = crashLogsDirectory() else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent(signalLogFileName).path
        if let existing = signalLogPathCString {
            free(existing)
        }
        signalLogPathCString = strdup(path)
    }
}

// MARK: - Signal Handler (C / async-signal-safe)

/// Writes a tiny breadcrumb with POSIX APIs only — Foundation is not safe here.
private func crashSignalHandler(_ signal: Int32) {
    if let path = CrashReporter.signalLogPathCString {
        let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        if fd >= 0 {
            // Fixed prefix + three signal digits + newline. No heap allocation.
            var bytes: [CChar] = [
                70, 97, 116, 97, 108, 32, 115, 105, 103, 110, 97, 108, 32, // "Fatal signal "
                48, 48, 48, 10 // digits + \n
            ]
            let value = max(signal, 0)
            bytes[13] = CChar((value / 100) % 10 + 48)
            bytes[14] = CChar((value / 10) % 10 + 48)
            bytes[15] = CChar(value % 10 + 48)
            bytes.withUnsafeBufferPointer { buf in
                _ = write(fd, buf.baseAddress, 17)
            }
            close(fd)
        }
    }

    // Re-raise with default handler so the system still generates a crash report.
    Darwin.signal(signal, SIG_DFL)
    raise(signal)
}

// MARK: - Convenience Functions

/// Logs a critical error that might lead to a crash
func logCritical(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
    CrashReporter.shared.logCriticalError(message, file: file, function: function, line: line)
}

/// Logs an error for debugging
func logError(_ message: String, error: Error? = nil, file: String = #file, function: String = #function, line: Int = #line) {
    CrashReporter.shared.logError(message, error: error, file: file, function: function, line: line)
}
