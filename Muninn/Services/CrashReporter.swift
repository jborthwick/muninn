import Foundation
import os

/// Simple crash and error reporting utility
final class CrashReporter {
    static let shared = CrashReporter()
    private let logger = Logger(subsystem: "com.personal.muninn", category: "crash")
    
    private init() {
        setupExceptionHandler()
    }
    
    /// Sets up NSException handler to catch Objective-C exceptions
    private func setupExceptionHandler() {
        NSSetUncaughtExceptionHandler { exception in
            let logger = Logger(subsystem: "com.personal.muninn", category: "crash")
            logger.critical("💥 UNCAUGHT EXCEPTION: \(exception.name.rawValue)")
            logger.critical("Reason: \(exception.reason ?? "unknown")")
            logger.critical("Stack trace: \(exception.callStackSymbols.joined(separator: "\n"))")
            
            // Save to file for later analysis
            CrashReporter.shared.saveCrashReport(
                type: "Exception",
                name: exception.name.rawValue,
                reason: exception.reason ?? "unknown",
                stackTrace: exception.callStackSymbols
            )
        }
    }
    
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
    
    /// Saves crash report to file
    private func saveCrashReport(type: String, name: String, reason: String, stackTrace: [String]) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        
        let report = """
        ==========================================
        POD PEACE CRASH REPORT
        ==========================================
        Type: \(type)
        Name: \(name)
        Time: \(timestamp)
        Reason: \(reason)
        
        Stack Trace:
        \(stackTrace.joined(separator: "\n"))
        ==========================================
        """
        
        // Save to Documents directory
        if let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            let crashLogPath = documentsPath.appendingPathComponent("CrashLogs", isDirectory: true)
            
            // Create directory if needed
            try? FileManager.default.createDirectory(at: crashLogPath, withIntermediateDirectories: true)
            
            let fileName = "crash-\(timestamp).txt"
            let filePath = crashLogPath.appendingPathComponent(fileName)
            
            do {
                try report.write(to: filePath, atomically: true, encoding: .utf8)
                logger.info("Crash report saved to: \(filePath.path)")
            } catch {
                logger.error("Failed to save crash report: \(error.localizedDescription)")
            }
        }
    }
    
    /// Returns all saved crash reports
    func getCrashReports() -> [URL] {
        guard let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return []
        }
        
        let crashLogPath = documentsPath.appendingPathComponent("CrashLogs", isDirectory: true)
        
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: crashLogPath,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        
        return files.sorted { url1, url2 in
            let date1 = (try? url1.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
            let date2 = (try? url2.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
            return date1 > date2
        }
    }
    
    /// Deletes all crash reports
    func clearCrashReports() {
        guard let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return
        }
        
        let crashLogPath = documentsPath.appendingPathComponent("CrashLogs", isDirectory: true)
        try? FileManager.default.removeItem(at: crashLogPath)
    }
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
