import Foundation
import OSLog

enum AppFlowDiagnostics {
    nonisolated private static let subsystem = Bundle.main.bundleIdentifier ?? "ArgentumVault"
    nonisolated private static let launchLogger = Logger(subsystem: subsystem, category: "LaunchFlow")
    nonisolated private static let syncLogger = Logger(subsystem: subsystem, category: "BackupSync")

    nonisolated static func launch(_ message: String) {
        launchLogger.notice("\(message, privacy: .public)")
    }

    nonisolated static func sync(_ message: String) {
        syncLogger.notice("\(message, privacy: .public)")
    }
}
