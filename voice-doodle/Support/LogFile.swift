import AppKit
import Foundation
import os.log

/// Direct os.log escape hatch for LogFile's own failures — writing through
/// Log.write would recurse back into LogFile.
private enum LogFileFallback {
    static let logger = Logger(subsystem: "com.xiabingquan.voice-doodle", category: "misc")
}

/// Plain-file debug log, one file per day under Application Support
/// `Voice Doodle/logs/`. The dashboard's view-log link opens today's file.
nonisolated enum LogFile {
    /// Injectable for tests; nil = Application Support/Voice Doodle/logs.
    static var directoryOverride: URL?
    private static let retentionDays = 7
    private static let queue = DispatchQueue(label: "com.xiabingquan.voice-doodle.logfile", qos: .utility)

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static var directoryURL: URL {
        if let directoryOverride { return directoryOverride }
        // Test-host guard, same principle as ConfigStore's scratch
        // directory — test fixtures must not write into the real daily log.
        if TestEnvironment.isTestHost {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "vd-testhost-logs-\(ProcessInfo.processInfo.processIdentifier)",
                    isDirectory: true
                )
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("Voice Doodle/logs", isDirectory: true)
    }

    static func fileURL(for date: Date = Date()) -> URL {
        directoryURL.appendingPathComponent("voice-doodle-\(dayFormatter.string(from: date)).log")
    }

    /// Appends one record to today's file as `timestamp [level] [category]
    /// message`. Newline-sanitized — every record is exactly one line.
    static func append(level: Log.Level, category: Log.Category, _ message: String) {
        let url = fileURL()
        let dir = directoryURL
        let single = Log.sanitize(message)
        let line = "\(timeFormatter.string(from: Date())) [\(level.rawValue)] [\(category.rawValue)] \(single)\n"
        queue.sync {
            let fm = FileManager.default
            do {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                if !fm.fileExists(atPath: url.path) {
                    try line.write(to: url, atomically: true, encoding: .utf8)
                } else {
                    let handle = try FileHandle(forWritingTo: url)
                    defer { try? handle.close() }
                    _ = try handle.seekToEnd()
                    try handle.write(contentsOf: Data(line.utf8))
                }
            } catch {
                // os.log only — must not recurse through Log.write → LogFile.
                LogFileFallback.logger.error("LogFile append failed: \(Log.describe(error))")
            }
        }
    }

    /// File the view-log link opens: today's when present, else the newest
    /// remaining file; creates today's when the directory holds none.
    static func fileToOpen() -> URL {
        let fm = FileManager.default
        let today = fileURL()
        if fm.fileExists(atPath: today.path) { return today }
        if let newest = existingFiles().last { return newest }
        try? fm.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try? "".write(to: today, atomically: true, encoding: .utf8)
        return today
    }

    /// Opens today's log file with the system default handler, the same
    /// mechanism as the open-config.json link.
    static func open() {
        purgeOldFiles()
        NSWorkspace.shared.open(fileToOpen())
    }

    /// Existing log files, oldest first (name sort = date sort).
    static func existingFiles() -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directoryURL.path)) ?? []
        return names
            .filter { $0.hasPrefix("voice-doodle-") && $0.hasSuffix(".log") }
            .sorted()
            .map { directoryURL.appendingPathComponent($0) }
    }

    /// Files older than the retention window are deleted on open so the
    /// directory cannot grow unbounded.
    static func purgeOldFiles(now: Date = Date()) {
        let fm = FileManager.default
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -retentionDays, to: now) else { return }
        for url in existingFiles() {
            let name = url.deletingPathExtension().lastPathComponent
            let day = String(name.dropFirst("voice-doodle-".count))
            if let date = dayFormatter.date(from: day), date < cutoff {
                try? fm.removeItem(at: url)
            }
        }
    }
}
