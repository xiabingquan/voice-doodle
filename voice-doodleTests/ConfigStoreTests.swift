import Testing
import Foundation
@testable import voice_doodle

@MainActor
struct ConfigStoreTests {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vd-config-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func firstLaunchWritesTemplate() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConfigStore(directory: dir)
        #expect(FileManager.default.fileExists(atPath: store.fileURL.path))
        #expect(store.loadError == nil)
        #expect(store.config.version == 3)
        #expect(store.config.asr.provider == .mimo)
        #expect(store.config.asr.openaiCompatible.model == "whisper-1")
        #expect(store.config.asr.mimo.baseURL.host == "api.xiaomimimo.com")
        #expect(store.config.asr.doubao.resourceID == "volc.seedasr.sauc.duration")
        // Grouping rule (v3): ASR under `asr`; legacy refine keys are dropped.
        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL)) as? [String: Any]
        #expect(raw?["asr"] != nil)
        // Legacy refine/postProcess blocks are not re-encoded.
        #expect(raw?["refine"] == nil)
        #expect(raw?["postProcess"] == nil)
        #expect(raw?["doubao"] == nil)
    }

    @Test func roundTripPersistsEdits() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConfigStore(directory: dir)
        store.update {
            $0.asr.openaiCompatible.apiKey = "sk-round-trip"
            $0.asr.openaiCompatible.prompt = "普通话"
            $0.asr.provider = .mimo
        }
        let reloaded = ConfigStore(directory: dir)
        #expect(reloaded.config.asr.openaiCompatible.apiKey == "sk-round-trip")
        #expect(reloaded.config.asr.openaiCompatible.prompt == "普通话")
        #expect(reloaded.config.asr.provider == .mimo)
    }

    @Test func resolvedTranscriptionReadsActiveProviderBlock() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConfigStore(directory: dir)
        store.update {
            $0.asr.provider = .doubao
            $0.asr.doubao.wsURL = URL(string: "wss://gw.example.com/asr")!
            $0.asr.doubao.apiKey = "doubao-key"
            $0.asr.doubao.resourceID = "custom.resource.id"
        }
        let resolved = store.config.resolvedTranscription
        #expect(resolved.provider == .doubao)
        // Built-in values win: custom URL/resourceID in the config block are ignored.
        #expect(resolved.baseURL == ASRBuiltIns.doubaoWsURL)
        #expect(resolved.model == ASRBuiltIns.doubaoResourceID)
        #expect(resolved.apiKey == "doubao-key")
        #expect(resolved.isConfigured)
    }

    @Test func mimoResolveUsesBuiltInsAndIgnoresConfigURL() throws {
        var config = AppConfig()
        config.asr.provider = .mimo
        config.asr.mimo.baseURL = URL(string: "https://custom.example.com/v1")!
        config.asr.mimo.model = "custom-model"
        config.asr.mimo.apiKey = "mimo-key"
        let resolved = config.resolvedTranscription
        #expect(resolved.baseURL == ASRBuiltIns.mimoBaseURL)
        #expect(resolved.model == ASRBuiltIns.mimoModel)
        #expect(resolved.apiKey == "mimo-key")
    }

    @Test func applyResolvedWritesOnlyAPIKeyForBuiltInProviders() {
        var config = AppConfig()
        config.asr.provider = .doubao
        var resolved = config.resolvedTranscription
        resolved.apiKey = "new-key"
        resolved.baseURL = URL(string: "wss://ignored.example.com")!
        config.applyResolvedTranscription(resolved)
        #expect(config.asr.doubao.apiKey == "new-key")
        // Endpoints/models are built-in: carrier-side changes are not
        // written back into the config block.
        #expect(config.asr.doubao.wsURL == ASRBuiltIns.doubaoWsURL)
        #expect(config.asr.doubao.resourceID == ASRBuiltIns.doubaoResourceID)
    }

    @Test func missingFieldsFallBackToBlockDefaults() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config.json")
        try Data(#"{"version":3,"asr":{"provider":"mimo","mimo":{"apiKey":"mimo-x"}}}"#.utf8).write(to: url)
        let store = ConfigStore(directory: dir)
        #expect(store.loadError == nil)
        #expect(store.config.asr.provider == .mimo)
        #expect(store.config.asr.mimo.apiKey == "mimo-x")
        #expect(store.config.asr.mimo.model == "mimo-v2.5-asr")   // block default
        #expect(store.config.asr.openaiCompatible.model == "whisper-1")
    }

    // MARK: - v1 → v3 migration

    @Test func v1ConfigMigratesToGroupedV3Blocks() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Real-world v1 shape: provider=doubao, model used as a human label.
        let url = dir.appendingPathComponent("config.json")
        try Data("""
        {"version":1,"transcription":{"baseURL":"https://api.openai.com/v1",
        "apiKey":"doubao-real-key","model":"bigmodel","provider":"doubao",
        "maxRecordDuration":120},"postProcess":{"enabled":true}}
        """.utf8).write(to: url)

        let store = ConfigStore(directory: dir)
        #expect(store.loadError == nil)
        #expect(store.config.asr.provider == .doubao)
        // Doubao block gets the probed, known-good endpoint values explicitly —
        // the v1 "bigmodel" label never leaks into resourceID.
        #expect(store.config.asr.doubao.resourceID == "volc.seedasr.sauc.duration")
        #expect(store.config.asr.doubao.wsURL.host == "openspeech.bytedance.com")
        #expect(store.config.asr.doubao.apiKey == "doubao-real-key")
        // The flat v1 fields land in the openai-compatible block untouched.
        #expect(store.config.asr.openaiCompatible.model == "bigmodel")
        #expect(store.config.general.maxRecordDuration == 120)
        // Migration persists: the file on disk is now grouped v3.
        let onDisk = try JSONDecoder().decode(AppConfig.self, from: Data(contentsOf: url))
        #expect(onDisk.version == 3)
        #expect(onDisk.asr.doubao.apiKey == "doubao-real-key")
    }

    // MARK: - v2 → v3 migration

    /// v2→v3 is a pure re-homing under `asr`: every value must survive,
    /// nothing may be reinterpreted; legacy refine keys are dropped.
    @Test func v2ConfigMigratesToGroupedV3Blocks() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config.json")
        try Data("""
        {"version":2,"provider":"doubao",
         "general":{"maxRecordDuration":240},
         "doubao":{"apiKey":"dk-v2","wsURL":"wss://openspeech.bytedance.com/api/v3/sauc/bigmodel",
                   "resourceID":"volc.seedasr.sauc.duration","requestTimeout":45},
         "mimo":{"apiKey":"mm-v2","baseURL":"https://api.xiaomimimo.com/v1","model":"mimo-v2.5-asr"},
         "openaiCompatible":{"apiKey":"sk-v2","model":"gpt-4o-transcribe","prompt":"普通话"},
         "postProcess":{"enabled":true,"apiKey":"or-v2","model":"qwen/qwen3-8b",
                        "systemPrompt":"润色提示词","requestTimeout":25}}
        """.utf8).write(to: url)

        let store = ConfigStore(directory: dir)
        #expect(store.loadError == nil)
        let cfg = store.config

        // Provider selection carried over into the asr block.
        #expect(cfg.asr.provider == .doubao)
        // Every provider block keeps its values verbatim.
        #expect(cfg.asr.doubao.apiKey == "dk-v2")
        #expect(cfg.asr.doubao.wsURL.absoluteString == "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel")
        #expect(cfg.asr.doubao.resourceID == "volc.seedasr.sauc.duration")
        #expect(cfg.asr.doubao.requestTimeout == 45)
        #expect(cfg.asr.mimo.apiKey == "mm-v2")
        #expect(cfg.asr.mimo.model == "mimo-v2.5-asr")
        #expect(cfg.asr.openaiCompatible.apiKey == "sk-v2")
        #expect(cfg.asr.openaiCompatible.model == "gpt-4o-transcribe")
        #expect(cfg.asr.openaiCompatible.prompt == "普通话")
        // Legacy postProcess values are dropped; asr fields survive unchanged.
        #expect(cfg.general.maxRecordDuration == 240)

        // Resolve still maps the active block through unchanged.
        let resolved = cfg.resolvedTranscription
        #expect(resolved.provider == .doubao)
        #expect(resolved.model == "volc.seedasr.sauc.duration")
        #expect(resolved.baseURL.host == "openspeech.bytedance.com")
        #expect(resolved.apiKey == "dk-v2")

        // On disk the file is now grouped v3…
        let onDiskRaw = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        #expect(onDiskRaw?["version"] as? Int == 3)
        #expect(onDiskRaw?["asr"] != nil)
        #expect(onDiskRaw?["refine"] == nil)
        #expect(onDiskRaw?["postProcess"] == nil)
        let onDisk = try JSONDecoder().decode(AppConfig.self, from: Data(contentsOf: url))
        #expect(onDisk.asr.doubao.apiKey == "dk-v2")
        // …and .bak holds the untouched v2 original.
        let bakURL = dir.appendingPathComponent("config.json.bak")
        #expect(FileManager.default.fileExists(atPath: bakURL.path))
        let bakRaw = try JSONSerialization.jsonObject(with: Data(contentsOf: bakURL)) as? [String: Any]
        #expect(bakRaw?["version"] as? Int == 2)
        #expect(bakRaw?["postProcess"] != nil)   // v2 original preserved verbatim
        #expect(bakRaw?["asr"] == nil)
    }

    // MARK: - Corruption protection

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

    // MARK: - mtime freshness gate

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
