import AppKit
import Combine
import Foundation
import os.log

/// Owns config.json under Application Support/Voice Doodle.
/// Injectable directory for tests; atomic writes; decode failures surface as
/// `loadError` and fall back to defaults — never crash.
@MainActor
final class ConfigStore: ObservableObject {
    @Published private(set) var config: AppConfig
    @Published private(set) var loadError: String?

    /// Fired after the file watcher reloads a genuinely changed config —
    /// AppState re-wires the session from here (load already happened).
    var onExternalChange: (() -> Void)?
    private var lastOwnWriteAt: Date?
    private var directoryWatcher: DispatchSourceFileSystemObject?
    private var reloadDebounce: DispatchWorkItem?
    /// config.json mtime at the last load()/write() — freshness baseline for
    /// `reloadIfFileChanged()`.
    private var lastReadFileMDate: Date?

    let directoryURL: URL
    var fileURL: URL { directoryURL.appendingPathComponent("config.json") }
    /// The config template lives beside config.json for reference and
    /// in-place copying.
    var templateURL: URL { directoryURL.appendingPathComponent("config_template.json") }
    private var backupURL: URL { directoryURL.appendingPathComponent("config.json.bak") }

    init(directory: URL? = nil) {
        if let directory {
            self.directoryURL = directory
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.directoryURL = base.appendingPathComponent("Voice Doodle", isDirectory: true)
        }
        self.config = AppConfig()
        // API keys may only be given explicitly by the user — no automatic
        // backfill from old config locations; such files are left in place,
        // neither read nor written.
        load()
        // Watcher only for the real location — injected test dirs stay quiet.
        if directory == nil {
            startWatching()
        }
    }

    func load() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: directoryURL.path) {
            try? fm.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        }
        guard fm.fileExists(atPath: fileURL.path) else {
            config = AppConfig()
            loadError = nil
            write(config)   // first launch: write the template
            return
        }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
            config = decoded
            loadError = nil
            lastReadFileMDate = fileMDate()
            Log.config.info("config.json loaded")
            persistMigrationIfNeeded(rawData: data)
        } catch {
            recoverFromCorruptConfig(primaryError: error)
        }
    }

    /// Files older than v3 are re-encoded to the current v3 schema right
    /// after decode; from then on hand edits target the new schema.
    private func persistMigrationIfNeeded(rawData: Data) {
        struct VersionPeek: Decodable { let version: Int? }
        guard let peek = try? JSONDecoder().decode(VersionPeek.self, from: rawData),
              (peek.version ?? 1) < 3 else { return }
        Log.config.info("config.json migrated → v3 schema")
        write(config)
    }

    /// Primary decode failed: try the backup, else fall back to defaults;
    /// either way the damaged file is renamed to preserve evidence so later
    /// writes can never silently destroy it.
    private func recoverFromCorruptConfig(primaryError: Error) {
        let fm = FileManager.default
        var messages: [String] = []

        if fm.fileExists(atPath: backupURL.path),
           let backupData = try? Data(contentsOf: backupURL),
           let recovered = try? JSONDecoder().decode(AppConfig.self, from: backupData) {
            config = recovered
            messages.append("已从备份 config.json.bak 恢复")
        } else {
            config = AppConfig()
            messages.append("已用默认值运行")
        }

        if let corruptURL = preserveCorruptFile() {
            messages.append("损坏文件已保留于 \(corruptURL.lastPathComponent)")
        }
        messages.append("原因：\(primaryError.localizedDescription)")
        loadError = messages.joined(separator: "；")
        Log.config.error("config decode failed: \(messages.joined(separator: "；"))")
    }

    /// Renames an unparseable config.json to config.json.corrupt-<timestamp>.
    @discardableResult
    private func preserveCorruptFile() -> URL? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let corruptURL = directoryURL.appendingPathComponent("config.json.corrupt-\(formatter.string(from: Date()))")
        do {
            try FileManager.default.moveItem(at: fileURL, to: corruptURL)
            return corruptURL
        } catch {
            Log.config.error("preserving corrupt config failed: \(String(describing: error))")
            return nil
        }
    }

    func save() {
        write(config)
    }

    /// Edit-and-save in one step (settings bindings).
    func update(_ mutate: (inout AppConfig) -> Void) {
        mutate(&config)
        write(config)
    }

    private func write(_ config: AppConfig) {
        let encoder = JSONEncoder()
        // withoutEscapingSlashes: URLs stay readable ("https://…" not "https:\/\/…").
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            let data = try encoder.encode(config)
            backupBeforeWrite()
            try data.write(to: fileURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            lastOwnWriteAt = Date()
            lastReadFileMDate = fileMDate()
        } catch {
            loadError = "配置写入失败：\(error.localizedDescription)"
            Log.config.error("config write failed: \(Log.describe(error))")
        }
    }

    /// Pre-write protection: an existing parseable file is copied to .bak;
    /// an unparseable one is renamed to .corrupt-* — damaged evidence is
    /// never silently overwritten.
    private func backupBeforeWrite() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else { return }
        if let data = try? Data(contentsOf: fileURL),
           (try? JSONDecoder().decode(AppConfig.self, from: data)) != nil {
            try? fm.removeItem(at: backupURL)
            try? fm.copyItem(at: fileURL, to: backupURL)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backupURL.path)
        } else {
            preserveCorruptFile()
        }
    }

    /// Opens the config file in the default editor.
    func openInEditor() {
        NSWorkspace.shared.open(fileURL)
    }

    /// Opens the config template for viewing/copying. The template ships
    /// inside the app bundle, which must not be edited (edits break code
    /// signature), so the first open copies it into the config directory.
    func openConfigTemplate() {
        ensureConfigTemplateExists()
        NSWorkspace.shared.open(templateURL)
    }

    /// Copies the template from the app bundle into the config directory
    /// when missing; an existing copy is left untouched, never overwriting
    /// user edits.
    private func ensureConfigTemplateExists() {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: templateURL.path) else { return }
        guard let bundled = Bundle.main.url(forResource: "config_template", withExtension: "json") else {
            Log.config.error("config_template.json missing from app bundle")
            return
        }
        do {
            try fm.copyItem(at: bundled, to: templateURL)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: templateURL.path)
        } catch {
            Log.config.error("config template copy failed: \(Log.describe(error))")
        }
    }

    // MARK: - External-change watching

    /// Watch the parent directory, not the file: atomic writes are renames,
    /// and an fd watching the file itself goes stale after replacement.
    private func startWatching() {
        guard directoryWatcher == nil else { return }
        let fd = open(directoryURL.path, O_EVTONLY)
        guard fd >= 0 else {
            Log.config.error("config watcher: open dir failed")
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            self?.directoryChanged()
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        directoryWatcher = source
        Log.config.info("config watcher started")
    }

    func stopWatching() {
        reloadDebounce?.cancel()
        reloadDebounce = nil
        directoryWatcher?.cancel()
        directoryWatcher = nil
    }

    private func directoryChanged() {
        // Own-write suppression: events in the short window after write()
        // come from our own disk flush.
        if let own = lastOwnWriteAt, Date().timeIntervalSince(own) < 0.5 { return }
        reloadDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.performExternalReload()
        }
        reloadDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func performExternalReload() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let before = try? JSONEncoder().encode(config)
        let previousLoadError = loadError
        load()
        let after = try? JSONEncoder().encode(config)
        guard before != after || loadError != previousLoadError else { return }
        Log.config.info("config.json changed externally; reloaded")
        onExternalChange?()
    }

    // MARK: - Freshness before key-dependent operations

    private func fileMDate() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.modificationDate] as? Date
    }

    /// Re-reads config.json when its mtime differs from the last
    /// load()/write(). Call before key-dependent operations — external edits
    /// must not run against a stale in-memory key.
    func reloadIfFileChanged() {
        guard let current = fileMDate() else { return }
        if let recorded = lastReadFileMDate, current == recorded { return }
        Log.config.info("config.json mtime changed on disk → reloading before use")
        performExternalReload()
        let after = config.asr
        Log.config.info("reloaded: provider=\(after.provider.rawValue) loadError=\(loadError ?? "nil")")
    }

    /// Resolved transcription for key-dependent operations: reloads from disk
    /// first when config.json was externally modified.
    func freshResolvedTranscription() -> TranscriptionConfig {
        reloadIfFileChanged()
        return config.resolvedTranscription
    }
}
