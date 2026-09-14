import Foundation
import Testing
@testable import voice_doodle

@MainActor
struct ConfigStoreHotwordTests {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vd-config-hotword-tests-\(UUID().uuidString)", isDirectory: true)
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
        // First launch seeds the preset; the default provider (MiMo-V2.5)
        // consumes hotwords, so the carrier already shows the seed table.
        #expect(store.freshResolvedTranscription().hotwords == HotwordPreset.load())

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
