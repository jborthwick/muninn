import Foundation
import os

/// Centralized logging for the app
enum AppLogger {
    static let audio = Logger(subsystem: "com.personal.muninn", category: "Audio")
    static let download = Logger(subsystem: "com.personal.muninn", category: "Download")
    static let sync = Logger(subsystem: "com.personal.muninn", category: "Sync")
    static let data = Logger(subsystem: "com.personal.muninn", category: "Data")
    static let feed = Logger(subsystem: "com.personal.muninn", category: "Feed")
    static let stats = Logger(subsystem: "com.personal.muninn", category: "Stats")
}
