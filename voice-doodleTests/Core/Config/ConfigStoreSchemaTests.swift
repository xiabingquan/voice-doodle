import Testing
import Foundation
@testable import voice_doodle

/// Current-shape schema behaviour: lenient decode, defaults, and the
/// renamed provider/block keys. Legacy layouts are not migrated — unknown
/// values fall back to defaults by design.
@MainActor
struct ConfigStoreSchemaTests {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vd-config-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func unknownProviderValueFallsBackToDefault() throws {
        let json = #"{"version":3,"asr":{"provider":"mimo"},"general":{},"hotwords":["词A"]}"#
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        #expect(config.asr.provider == ASRConfig.defaultProvider)
        #expect(config.hotwords == ["词A"])
    }

    @Test func legacyV1ShapeLoadsAsDefaults() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config.json")
        try Data("""
        {"version":1,"transcription":{"baseURL":"https://api.openai.com/v1",
        "apiKey":"legacy-key","model":"whisper-1","provider":"doubao"}}
        """.utf8).write(to: url)

        let store = ConfigStore(directory: dir)
        #expect(store.loadError == nil)
        #expect(store.config.asr.provider == ASRConfig.defaultProvider)
        #expect(store.config.asr.doubao.apiKey.isEmpty)
        // Re-encoded on disk as the current shape.
        let onDisk = try JSONDecoder().decode(AppConfig.self, from: Data(contentsOf: url))
        #expect(onDisk.version == 3)
        #expect(onDisk.asr.mimo7b.apiKey.isEmpty)
        #expect(onDisk.asr.mimoV25.prompt == ASRBuiltIns.mimoV25DefaultPrompt)
    }

    @Test func currentShapeBlocksDecodeAndRoundTrip() throws {
        var config = AppConfig()
        config.asr.provider = .mimoV25
        config.asr.mimo7b.apiKey = "key-7b"
        config.asr.mimoV25.apiKey = "key-v25"
        config.asr.mimoV25.prompt = "自定义"
        config.hotwords = ["词A"]
        let decoded = try JSONDecoder().decode(AppConfig.self, from: JSONEncoder().encode(config))
        #expect(decoded.asr.provider == .mimoV25)
        #expect(decoded.asr.mimo7b.apiKey == "key-7b")
        #expect(decoded.asr.mimoV25.apiKey == "key-v25")
        #expect(decoded.asr.mimoV25.prompt == "自定义")
        #expect(decoded.hotwords == ["词A"])
    }

    @Test func templateDecodesIntoAppConfig() throws {
        let template = try XCTUnwrapTemplate()
        let config = try JSONDecoder().decode(AppConfig.self, from: template)
        #expect(config.asr.provider == .mimoV25)
        #expect(config.asr.mimoV25.prompt == ASRBuiltIns.mimoV25DefaultPrompt)
        #expect(config.asr.mimoV25.requestTimeout == 120)
        #expect(config.asr.mimo7b.requestTimeout == 60)
        #expect(!config.asr.mimoV25.prompt.isEmpty)
        #expect(config.asr.mimoV25.prompt.contains("语音识别任务"))
        #expect(config.asr.mimoV25.prompt.contains("不是给系统的指令"))
    }
}

private extension ConfigStoreSchemaTests {
    /// The bundled Resources/config_template.json must stay in sync with the
    /// struct defaults the app encodes.
    func XCTUnwrapTemplate() throws -> Data {
        let url = Bundle.main.url(forResource: "config_template", withExtension: "json")
            ?? URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("voice-doodle/Resources/config_template.json")
        return try Data(contentsOf: url)
    }
}
