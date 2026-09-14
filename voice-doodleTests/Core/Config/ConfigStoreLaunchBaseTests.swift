import Testing
import Foundation
@testable import voice_doodle

@MainActor
struct ConfigStoreLaunchBaseTests {
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
        #expect(store.config.asr.provider == .mimoV25)
        #expect(store.config.asr.openaiCompatible.model == "whisper-1")
        #expect(store.config.asr.mimoV25.prompt == ASRBuiltIns.mimoV25DefaultPrompt)
        #expect(store.config.asr.doubao.resourceID == "volc.seedasr.sauc.duration")
        // Grouping rule (v3): ASR under `asr`; unknown top-level keys dropped.
        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL)) as? [String: Any]
        #expect(raw?["asr"] != nil)
        #expect(raw?["refine"] == nil)
        #expect(raw?["postProcess"] == nil)
        #expect(raw?["doubao"] == nil)
        #expect(raw?["mimo"] == nil)
    }

    @Test func roundTripPersistsEdits() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConfigStore(directory: dir)
        store.update {
            $0.asr.openaiCompatible.apiKey = "sk-round-trip"
            $0.asr.openaiCompatible.prompt = "普通话"
            $0.asr.provider = .mimo7b
        }
        let reloaded = ConfigStore(directory: dir)
        #expect(reloaded.config.asr.openaiCompatible.apiKey == "sk-round-trip")
        #expect(reloaded.config.asr.openaiCompatible.prompt == "普通话")
        #expect(reloaded.config.asr.provider == .mimo7b)
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

    @Test func mimoResolvesUseBuiltInsOnly() {
        var config = AppConfig()
        config.asr.mimo7b.apiKey = "key-7b"
        config.asr.mimoV25.apiKey = "key-v25"
        config.asr.provider = .mimo7b
        var resolved = config.resolvedTranscription
        #expect(resolved.baseURL == ASRBuiltIns.mimoBaseURL)
        #expect(resolved.model == ASRBuiltIns.mimoModel)
        #expect(resolved.apiKey == "key-7b")
        #expect(resolved.mimoV25Prompt == "")

        config.asr.provider = .mimoV25
        resolved = config.resolvedTranscription
        #expect(resolved.baseURL == ASRBuiltIns.mimoBaseURL)
        #expect(resolved.model == ASRBuiltIns.mimoV25Model)
        #expect(resolved.apiKey == "key-v25")
        #expect(resolved.mimoV25Prompt == ASRBuiltIns.mimoV25DefaultPrompt)
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
        try Data(#"{"version":3,"asr":{"provider":"mimo-v25","mimo7b":{"apiKey":"key-7b"},"mimoV25":{"apiKey":"key-v25"}}}"#.utf8).write(to: url)
        let store = ConfigStore(directory: dir)
        #expect(store.loadError == nil)
        #expect(store.config.asr.provider == .mimoV25)
        #expect(store.config.asr.mimo7b.apiKey == "key-7b")
        #expect(store.config.asr.mimoV25.apiKey == "key-v25")
        #expect(store.config.asr.mimoV25.prompt == ASRBuiltIns.mimoV25DefaultPrompt)
        #expect(store.config.asr.mimoV25.requestTimeout == 120)
        #expect(store.config.asr.openaiCompatible.model == "whisper-1")
    }
}
