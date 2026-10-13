import Foundation
import OSLog

struct AppLogger {
    let category: String

    func debug(_ message: String) { record(.debug, message) }
    func info(_ message: String) { record(.info, message) }
    func warning(_ message: String) { record(.warning, message) }
    func error(_ message: String) { record(.error, message) }

    private func record(_ level: AppLogEntry.Level, _ message: String) {
        let entry = AppLogEntry(level: level, category: category, message: message)
        AppLogStore.shared.record(entry)
        let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.signos.app", category: category)
        switch level {
        case .debug: logger.debug("\(entry.message, privacy: .private)")
        case .info: logger.info("\(entry.message, privacy: .private)")
        case .warning: logger.warning("\(entry.message, privacy: .private)")
        case .error: logger.error("\(entry.message, privacy: .private)")
        }
    }
}
