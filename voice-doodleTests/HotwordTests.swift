import Foundation
import Testing
@testable import voice_doodle

struct HotwordTests {
    // MARK: - HotwordPreset

    @Test func parseSkipsCommentsBlanksAndDuplicates() {
        let text = """
        # comment line

          词A
        词A
         词B
        #词C
        """
        #expect(HotwordPreset.parse(text) == ["词A", "词B"])
    }

    @Test func loadFromMissingURLIsEmpty() {
        #expect(HotwordPreset.load(from: nil) == [])
    }

    @Test func loadReadsFixtureFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hotwords-\(UUID().uuidString).txt")
        try "# c\n词X\n词Y\n".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(HotwordPreset.load(from: url) == ["词X", "词Y"])
    }

    // MARK: - Cap

    @Test func capTrimsDedupesAndPreservesOrder() {
        let capped = DoubaoClient.cappedHotwords(
            [" 词A ", "", "词B", "词A", "词C"],
            wsURL: ASRBuiltIns.doubaoWsURL
        )
        #expect(capped == ["词A", "词B", "词C"])
    }

    @Test func capNostreamAllows5000() {
        let words = (0..<5001).map { "词\($0)" }
        #expect(DoubaoClient.cappedHotwords(words, wsURL: ASRBuiltIns.doubaoWsURL).count == 5000)
    }

    @Test func capStreamingDropsTo100() {
        let streamURL = URL(string: "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel")!
        let words = (0..<150).map { "词\($0)" }
        #expect(DoubaoClient.cappedHotwords(words, wsURL: streamURL).count == 100)
    }

    // MARK: - Start frame

    @Test func startFrameOmitsCorpusWhenNoHotwords() throws {
        let data = DoubaoClient.startRequestBody(enablePunc: true, enableITN: true, enableDDC: true)
        let body = String(data: data, encoding: .utf8) ?? ""
        #expect(body.contains("\"enable_punc\":true"))
        #expect(!body.contains("corpus"))
    }

    @Test func startFrameCarriesHotwordsAsEscapedContextString() throws {
        let data = DoubaoClient.startRequestBody(
            enablePunc: true, enableITN: true, enableDDC: true,
            hotwords: ["热词1号", "Voice Doodle"]
        )
        let frame = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let request = try #require(frame["request"] as? [String: Any])
        let corpus = try #require(request["corpus"] as? [String: Any])
        let context = try #require(corpus["context"] as? String)
        let inner = try #require(try JSONSerialization.jsonObject(with: Data(context.utf8)) as? [String: Any])
        let words = try #require(inner["hotwords"] as? [[String: Any]])
        #expect(words.count == 2)
        #expect(words.compactMap { $0["word"] as? String } == ["热词1号", "Voice Doodle"])
        #expect((frame["audio"] as? [String: Any])?["rate"] as? Int == 16000)
    }

    // MARK: - Config schema: file is authoritative

    @Test func decodeMissingHotwordsKeyIsEmpty() throws {
        let json = #"{"version":3,"asr":{"provider":"doubao"},"general":{}}"#
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        #expect(config.hotwords == [])
    }

    @Test func decodeExplicitEmptyHotwordsStaysEmpty() throws {
        let json = #"{"version":3,"asr":{"provider":"doubao"},"general":{},"hotwords":[]}"#
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        #expect(config.hotwords == [])
    }

    @Test func decodeExplicitHotwordsRoundTrip() throws {
        var config = AppConfig()
        config.hotwords = ["词A", "词B"]
        let decoded = try JSONDecoder().decode(AppConfig.self, from: JSONEncoder().encode(config))
        #expect(decoded.hotwords == ["词A", "词B"])
    }

    @Test func resolvedTranscriptionCarriesHotwordsForDoubaoOnly() {
        var config = AppConfig()
        config.hotwords = ["词A"]
        config.asr.provider = .doubao
        #expect(config.resolvedTranscription.hotwords == ["词A"])
        config.asr.provider = .mimo
        #expect(config.resolvedTranscription.hotwords == [])
        config.asr.provider = .openaiCompatible
        #expect(config.resolvedTranscription.hotwords == [])
    }

    @Test func applyResolvedOnDoubaoWritesHotwordsBack() {
        var config = AppConfig()
        config.hotwords = ["词A"]
        config.asr.provider = .doubao
        var resolved = config.resolvedTranscription
        resolved.hotwords = ["词B", "词C"]
        config.applyResolvedTranscription(resolved)
        #expect(config.hotwords == ["词B", "词C"])
    }

    @Test func applyResolvedOnOtherProvidersLeavesHotwordsUntouched() {
        var config = AppConfig()
        config.hotwords = ["词A"]
        config.asr.provider = .openaiCompatible
        var resolved = config.resolvedTranscription
        resolved.hotwords = ["不该写回"]
        config.applyResolvedTranscription(resolved)
        #expect(config.hotwords == ["词A"])
    }

    // MARK: - ConfigStore: file-authoritative sync

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vd-hotword-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// First launch writes config.json with the preset seed (empty in tests).
    @MainActor
    @Test func firstLaunchPersistsPresetSeedInConfigFile() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConfigStore(directory: dir)
        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL)) as? [String: Any]
        #expect(raw?["hotwords"] as? [String] == HotwordPreset.load())
    }

    /// Existing config without the key: file untouched, hotwords empty.
    @MainActor
    @Test func loadDoesNotWriteHotwordsKeyWhenMissing() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let legacy = #"{"version":3,"asr":{"provider":"doubao"},"general":{"maxRecordDuration":300}}"#
        try Data(legacy.utf8).write(to: dir.appendingPathComponent("config.json"))

        let store = ConfigStore(directory: dir)
        #expect(store.config.hotwords == [])
        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL)) as? [String: Any]
        #expect(raw?["hotwords"] == nil)
    }

    /// External edit of hotwords is picked up on reload.
    @MainActor
    @Test func externalEditUpdatesInMemoryHotwords() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConfigStore(directory: dir)
        #expect(store.freshResolvedTranscription().hotwords == [])

        let edited = #"{"version":3,"asr":{"provider":"doubao"},"general":{"maxRecordDuration":300},"hotwords":["词Z"]}"#
        let url = store.fileURL
        try Data(edited.utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: 120)],
            ofItemAtPath: url.path
        )
        #expect(store.freshResolvedTranscription().hotwords == ["词Z"])
    }
}
