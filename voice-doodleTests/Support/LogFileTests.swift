import Foundation
import Testing
@testable import voice_doodle

/// LogFile + Log taxonomy tests. Writes go through an injected directory; the
/// suite is serialized because `directoryOverride` is process-global.
@Suite(.serialized)
@MainActor
struct LogFileTests {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vd-logfile-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func withOverride<T>(_ dir: URL, _ body: () throws -> T) rethrows -> T {
        LogFile.directoryOverride = dir
        defer { LogFile.directoryOverride = nil }
        return try body()
    }

    @Test func dailyFileNameContainsDate() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try withOverride(dir) {
            let day = Date(timeIntervalSince1970: 1_789_000_000) // fixed instant
            let name = LogFile.fileURL(for: day).lastPathComponent
            #expect(name.hasPrefix("voice-doodle-"))
            #expect(name.hasSuffix(".log"))
            #expect(name.count == "voice-doodle-".count + 10 + ".log".count)
        }
    }

    @Test func appendWritesUnifiedFormatLine() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try withOverride(dir) {
            LogFile.append(level: .info, category: .test, "hello")
            LogFile.append(level: .error, category: .asr, "world")
            let content = try String(contentsOf: LogFile.fileURL(), encoding: .utf8)
            let lines = content.split(separator: "\n")
            #expect(lines.count == 2)
            #expect(lines[0].contains("[info] [test] hello"))
            #expect(lines[1].contains("[error] [asr] world"))
            #expect(lines[0].hasPrefix("20")) // timestamped
        }
    }

    /// Single-line rule: multi-line messages must never split a record
    /// across lines — analysis depends on it.
    @Test func multiLineMessageIsSanitizedToSingleLine() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try withOverride(dir) {
            Log.test.error("FAILED\nprovider: doubao\r\nbody: x\ry")
            let content = try String(contentsOf: LogFile.fileURL(), encoding: .utf8)
            let lines = content.split(separator: "\n")
            #expect(lines.count == 1)
            #expect(lines[0].contains("[error] [test] FAILED provider: doubao body: x y"))
        }
    }

    /// Category names must not collide with level names — the catch-all
    /// category is `misc`, never `debug`.
    @Test func taxonomyIsEnumerableAndDisjointFromLevels() {
        #expect(Log.Category.allCases.map(\.rawValue) ==
                ["test", "asr", "config", "session", "hotkey", "insertion", "hud", "audio", "misc"])
        #expect(Log.Level.allCases.map(\.rawValue) == ["debug", "info", "warning", "error"])
        let levelNames = Set(Log.Level.allCases.map(\.rawValue))
        for category in Log.Category.allCases {
            #expect(!levelNames.contains(category.rawValue))
        }
    }

    @Test func purgeDeletesFilesOlderThanRetention() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try withOverride(dir) {
            let fm = FileManager.default
            let old = dir.appendingPathComponent("voice-doodle-2020-01-01.log")
            let recent = dir.appendingPathComponent(LogFile.fileURL().lastPathComponent)
            try "old".write(to: old, atomically: true, encoding: .utf8)
            try "recent".write(to: recent, atomically: true, encoding: .utf8)

            LogFile.purgeOldFiles()

            #expect(!fm.fileExists(atPath: old.path))
            #expect(fm.fileExists(atPath: recent.path))
        }
    }

    @Test func fileToOpenFallsBackToNewestExisting() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try withOverride(dir) {
            let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
            let yesterdayURL = LogFile.fileURL(for: yesterday)
            try "yesterday".write(to: yesterdayURL, atomically: true, encoding: .utf8)
            #expect(LogFile.fileToOpen() == yesterdayURL)
        }
    }

    @Test func fileToOpenCreatesTodayWhenDirectoryEmpty() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try withOverride(dir) {
            let url = LogFile.fileToOpen()
            #expect(url == LogFile.fileURL())
            #expect(FileManager.default.fileExists(atPath: url.path))
        }
    }

    /// Test-host runs must never log into the production logs directory.
    @Test func testHostLogsNeverUseProductionDirectory() {
        #expect(TestEnvironment.isTestHost)
        LogFile.directoryOverride = nil
        #expect(LogFile.directoryURL != TestEnvironment.productionConfigDirectory.appendingPathComponent("logs"))
        #expect(!LogFile.directoryURL.path.contains("Application Support/Voice Doodle"))
    }
}
