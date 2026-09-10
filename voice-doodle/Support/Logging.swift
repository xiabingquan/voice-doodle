import Foundation
import os.log

/// Unified log taxonomy: every line carries an enumerable category and a
/// strict level (debug/info/warning/error), written to both os.log and the
/// daily file log. Messages are newline-sanitized at the write boundary.
enum Log {

    /// Enumerable log categories — single source for both sinks.
    enum Category: String, CaseIterable, Sendable {
        case test       // dashboard connectivity test
        case asr        // transcription requests / ASR backends
        case config     // config.json load, reload, migration
        case session    // state machine, readiness, app lifecycle
        case hotkey     // trigger engine
        case insertion  // AX write / paste / pasteboard
        case hud        // HUD panel and its views
        case audio      // recorder, VAD, encoder
        case misc       // everything else (cleanup agent, misc internals)
    }

    enum Level: String, CaseIterable, Sendable {
        case debug, info, warning, error
    }

    private static let subsystem = "com.xiabingquan.voice-doodle"
    private static let loggers = LoggerCache()

    static let test = Channel(.test)
    static let asr = Channel(.asr)
    static let config = Channel(.config)
    static let session = Channel(.session)
    static let hotkey = Channel(.hotkey)
    static let insertion = Channel(.insertion)
    static let hud = Channel(.hud)
    static let audio = Channel(.audio)
    static let misc = Channel(.misc)

    /// Uniform error label for log interpolation.
    static func describe(_ error: Error) -> String {
        String(describing: error)
    }

    /// Fixed-precision number formatting for messages (replaces os.log
    /// `format:` annotations, which are unavailable at plain-String call
    /// sites).
    static func fixed(_ value: Double, _ digits: Int = 2) -> String {
        String(format: "%.\(digits)f", value)
    }

    /// Category-scoped channel. Both sinks receive the same sanitized line.
    struct Channel: Sendable {
        let category: Category

        init(_ category: Category) { self.category = category }

        func debug(_ message: String) { Log.write(.debug, category, message) }
        func info(_ message: String) { Log.write(.info, category, message) }
        func warning(_ message: String) { Log.write(.warning, category, message) }
        func error(_ message: String) { Log.write(.error, category, message) }
    }

    /// The single write boundary: sanitize to one line, then fan out to
    /// os.log (public) and the daily file log.
    static func write(_ level: Level, _ category: Category, _ message: String) {
        let single = sanitize(message)
        let logger = loggers.logger(for: subsystem, category: category.rawValue)
        switch level {
        case .debug: logger.debug("\(single)")
        case .info: logger.info("\(single)")
        case .warning: logger.warning("\(single)")
        case .error: logger.error("\(single)")
        }
        LogFile.append(level: level, category: category, single)
    }

    /// Single-line enforcement: any embedded newline becomes a space so
    /// each record occupies exactly one line.
    static func sanitize(_ message: String) -> String {
        message
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }
}

/// Logger instances are cheap but rebuilding one per line is wasteful; cache
/// per category. os.Logger is thread-safe.
private final class LoggerCache: @unchecked Sendable {
    private let lock = NSLock()
    private var cache: [String: Logger] = [:]

    func logger(for subsystem: String, category: String) -> Logger {
        lock.lock()
        defer { lock.unlock() }
        if let existing = cache[category] { return existing }
        let created = Logger(subsystem: subsystem, category: category)
        cache[category] = created
        return created
    }
}
