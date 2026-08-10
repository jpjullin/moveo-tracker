import AppKit
import Foundation

final class Diagnostics {
    static let shared = Diagnostics()
    static let supportEmail = "jeanphilippe.jullin@gmail.com"

    private let queue = DispatchQueue(label: "site.posedtx.moveo-tracker.diagnostics")
    private let fileManager = FileManager.default
    private let logsDirectory: URL
    private let markerURL: URL
    private let sessionLogURL: URL

    private init() {
        let logsRoot = fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Logs", isDirectory: true)
        logsDirectory = logsRoot.appendingPathComponent("Moveo Tracker", isDirectory: true)

        let supportRoot = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Moveo Tracker", isDirectory: true)
        markerURL = supportRoot.appendingPathComponent("session-active")

        let stamp = Self.fileStamp(from: Date())
        sessionLogURL = logsDirectory.appendingPathComponent("session-\(stamp).log")
    }

    @discardableResult
    func beginSession() -> Bool {
        let previousSessionWasInterrupted = fileManager.fileExists(atPath: markerURL.path)
        do {
            try fileManager.createDirectory(
                at: logsDirectory,
                withIntermediateDirectories: true
            )
            try fileManager.createDirectory(
                at: markerURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            pruneOldSessionLogs()
            try Data(Self.timestamp().utf8).write(to: markerURL, options: .atomic)
            record("Session started | app \(Self.appVersion) | macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
            if previousSessionWasInterrupted {
                record("Previous session did not close cleanly")
            }
        } catch {
            NSLog("Moveo Tracker diagnostics setup failed: %@", error.localizedDescription)
        }
        return previousSessionWasInterrupted
    }

    func record(_ message: String) {
        let line = "[\(Self.timestamp())] \(message)\n"
        queue.async { [fileManager, sessionLogURL] in
            do {
                if !fileManager.fileExists(atPath: sessionLogURL.path) {
                    fileManager.createFile(atPath: sessionLogURL.path, contents: nil)
                }
                let handle = try FileHandle(forWritingTo: sessionLogURL)
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(line.utf8))
                try handle.close()
            } catch {
                NSLog("Moveo Tracker log write failed: %@", error.localizedDescription)
            }
        }
    }

    func endSession() {
        record("Session closed cleanly")
        queue.sync {}
        try? fileManager.removeItem(at: markerURL)
    }

    func makeArchive() throws -> URL {
        record("Creating diagnostic archive")
        queue.sync {}
        collectRecentCrashReports()

        let summary = """
        Moveo Tracker diagnostics
        Created: \(Self.timestamp())
        App: \(Self.appVersion)
        macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)
        Support: \(Self.supportEmail)
        """
        try Data(summary.utf8).write(
            to: logsDirectory.appendingPathComponent("system-info.txt"),
            options: .atomic
        )

        let archiveURL = logsDirectory.deletingLastPathComponent()
            .appendingPathComponent("Moveo-Tracker-Diagnostics-\(Self.fileStamp(from: Date())).zip")
        let process = Process()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", logsDirectory.path, archiveURL.path]
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8) ?? "Unknown archive error"
            throw DiagnosticsError.archiveFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return archiveURL
    }

    private func pruneOldSessionLogs() {
        guard let files = try? fileManager.contentsOfDirectory(
            at: logsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let logs = files
            .filter { $0.lastPathComponent.hasPrefix("session-") && $0.pathExtension == "log" }
            .sorted {
                let left = try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                let right = try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                return (left ?? .distantPast) > (right ?? .distantPast)
            }
        for oldLog in logs.dropFirst(9) {
            try? fileManager.removeItem(at: oldLog)
        }
    }

    private func collectRecentCrashReports() {
        let reportSource = logsDirectory.deletingLastPathComponent()
            .appendingPathComponent("DiagnosticReports", isDirectory: true)
        guard let reports = try? fileManager.contentsOfDirectory(
            at: reportSource,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let cutoff = Date().addingTimeInterval(-7 * 24 * 60 * 60)
        let matching = reports.filter { url in
            let name = url.lastPathComponent.lowercased()
            guard name.contains("moveotracker") || name.contains("moveo tracker") else {
                return false
            }
            let date = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate
            return (date ?? .distantPast) >= cutoff
        }
        guard !matching.isEmpty else { return }

        let destination = logsDirectory.appendingPathComponent("Crash Reports", isDirectory: true)
        try? fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        for report in matching {
            let copy = destination.appendingPathComponent(report.lastPathComponent)
            if fileManager.fileExists(atPath: copy.path) { try? fileManager.removeItem(at: copy) }
            try? fileManager.copyItem(at: report, to: copy)
        }
    }

    private static var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "development"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            ?? "unknown"
        return "\(version) (\(build))"
    }

    private static func timestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }

    private static func fileStamp(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }
}

private enum DiagnosticsError: LocalizedError {
    case archiveFailed(String)

    var errorDescription: String? {
        switch self {
        case .archiveFailed(let message):
            return "Could not create the diagnostic ZIP: \(message)"
        }
    }
}
