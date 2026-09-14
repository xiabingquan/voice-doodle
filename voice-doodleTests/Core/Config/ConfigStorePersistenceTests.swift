import Testing
import Foundation
@testable import voice_doodle

@MainActor
struct ConfigStorePersistenceTests {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vd-config-persist-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    @Test func updateBacksUpPreviousValidConfig() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConfigStore(directory: dir)
        store.update { $0.asr.openaiCompatible.apiKey = "sk-first" }
        store.update { $0.asr.openaiCompatible.apiKey = "sk-second" }

        let backupURL = dir.appendingPathComponent("config.json.bak")
        #expect(FileManager.default.fileExists(atPath: backupURL.path))
        let backup = try JSONDecoder().decode(
            AppConfig.self, from: Data(contentsOf: backupURL)
        )
        #expect(backup.asr.openaiCompatible.apiKey == "sk-first")
        #expect(store.config.asr.openaiCompatible.apiKey == "sk-second")
    }

    @Test func corruptConfigRecoversFromBackup() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConfigStore(directory: dir)
        store.update { $0.asr.openaiCompatible.apiKey = "sk-saved" }   // seeds config.json
        store.update { $0.asr.openaiCompatible.prompt = "p" }          // moves first write into .bak
        try Data("not json at all".utf8).write(to: store.fileURL)

        let reloaded = ConfigStore(directory: dir)
        #expect(reloaded.loadError != nil)
        #expect(reloaded.loadError?.contains("备份") == true)
        #expect(reloaded.config.asr.openaiCompatible.apiKey == "sk-saved")
        let corrupt = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix("config.json.corrupt-") }
        #expect(corrupt.count == 1)
    }

    @Test func corruptWithoutBackupKeepsEvidenceAndSurvivesUpdate() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config.json")
        try Data("not json at all".utf8).write(to: url)

        let store = ConfigStore(directory: dir)
        #expect(store.loadError != nil)
        #expect(store.config.asr.openaiCompatible.model == "whisper-1")
        let corruptFiles = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix("config.json.corrupt-") }
        #expect(corruptFiles.count == 1)
        let evidence = try String(contentsOf: dir.appendingPathComponent(corruptFiles[0]), encoding: .utf8)
        #expect(evidence == "not json at all")

        // A settings edit afterwards must not destroy the preserved evidence.
        store.update { $0.asr.openaiCompatible.apiKey = "sk-new" }
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent(corruptFiles[0]).path))
        #expect(store.config.asr.openaiCompatible.apiKey == "sk-new")
    }

    @Test func resolvedTranscriptionNormalizesTrailingSlash() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConfigStore(directory: dir)
        store.update {
            $0.asr.provider = .openaiCompatible
            $0.asr.openaiCompatible.baseURL = URL(string: "https://gw.example.com/v1/")!
        }
        // The block stores the file verbatim; normalization happens only at
        // the resolve boundary (no hidden rewriting of the user's file).
        #expect(store.config.asr.openaiCompatible.baseURL.absoluteString == "https://gw.example.com/v1/")
        #expect(store.config.resolvedTranscription.baseURL.absoluteString == "https://gw.example.com/v1")
    }
    /// Simulates an external editor save: new content, mtime pushed forward.
    private func writeExternalConfig(_ store: ConfigStore, mutate: (inout AppConfig) -> Void) throws {
        var external = store.config
        mutate(&external)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(external).write(to: store.fileURL)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: 120)],
            ofItemAtPath: store.fileURL.path
        )
    }

    @Test func reloadIfFileChangedPicksUpExternalEdit() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConfigStore(directory: dir)
        store.update { $0.asr.doubao.apiKey = "sk-original" }
        var changeCount = 0
        store.onExternalChange = { changeCount += 1 }

        try writeExternalConfig(store) {
            $0.asr.provider = .doubao
            $0.asr.doubao.apiKey = "sk-wrong-external"
        }
        store.reloadIfFileChanged()

        #expect(store.config.asr.doubao.apiKey == "sk-wrong-external")
        #expect(changeCount == 1)
    }

    @Test func reloadIfFileChangedIsNoOpWhenFileUntouched() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConfigStore(directory: dir)
        store.update { $0.asr.openaiCompatible.apiKey = "sk-keep" }
        var changeCount = 0
        store.onExternalChange = { changeCount += 1 }

        store.reloadIfFileChanged()

        #expect(store.config.asr.openaiCompatible.apiKey == "sk-keep")
        #expect(changeCount == 0)
    }

    @Test func ownWriteDoesNotTriggerReload() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConfigStore(directory: dir)
        var changeCount = 0
        store.onExternalChange = { changeCount += 1 }

        store.update { $0.asr.openaiCompatible.apiKey = "sk-own-write" }
        store.reloadIfFileChanged()

        #expect(store.config.asr.openaiCompatible.apiKey == "sk-own-write")
        #expect(changeCount == 0)
    }

    @Test func freshResolvedTranscriptionSeesExternalEdit() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConfigStore(directory: dir)
        store.update {
            $0.asr.provider = .doubao
            $0.asr.doubao.apiKey = "sk-original"
        }
        #expect(store.freshResolvedTranscription().apiKey == "sk-original")

        try writeExternalConfig(store) {
            $0.asr.doubao.apiKey = "sk-edited-on-disk"
        }
        let fresh = store.freshResolvedTranscription()
        #expect(fresh.provider == .doubao)
        #expect(fresh.apiKey == "sk-edited-on-disk")
    }
}
