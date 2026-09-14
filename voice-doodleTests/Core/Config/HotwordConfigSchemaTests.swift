import Foundation
import Testing
@testable import voice_doodle

/// Hotword carrier matrix: one top-level table, per-backend consumption.
/// Doubao (API corpus) and MiMo-V2.5 (prompt) carry it; MiMo-7B and
/// openai-compatible must never see it.
struct HotwordConfigSchemaTests {
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

    @Test func resolvedHotwordsFollowProviderMatrix() {
        var config = AppConfig()
        config.hotwords = ["词A"]
        config.asr.provider = .doubao
        #expect(config.resolvedTranscription.hotwords == ["词A"])
        config.asr.provider = .mimoV25
        #expect(config.resolvedTranscription.hotwords == ["词A"])
        config.asr.provider = .mimo7b
        #expect(config.resolvedTranscription.hotwords == [])
        config.asr.provider = .openaiCompatible
        #expect(config.resolvedTranscription.hotwords == [])
    }

    @Test func mimo7bResolveCarriesNoPromptEither() {
        var config = AppConfig()
        config.hotwords = ["词A"]
        config.asr.provider = .mimo7b
        let resolved = config.resolvedTranscription
        #expect(resolved.hotwords == [])
        #expect(resolved.mimoV25Prompt == "")
    }

    @Test func mimoV25ResolveCarriesPromptAndHotwords() {
        var config = AppConfig()
        config.hotwords = ["词A", "词B"]
        config.asr.provider = .mimoV25
        config.asr.mimoV25.prompt = "自定义提示词"
        let resolved = config.resolvedTranscription
        #expect(resolved.mimoV25Prompt == "自定义提示词")
        #expect(resolved.hotwords == ["词A", "词B"])
        #expect(resolved.model == ASRBuiltIns.mimoV25Model)
        #expect(resolved.requestTimeout == 120)
    }

    @Test func applyResolvedWritesHotwordsBackForConsumersOnly() {
        var doubao = AppConfig()
        doubao.hotwords = ["词A"]
        doubao.asr.provider = .doubao
        var resolved = doubao.resolvedTranscription
        resolved.hotwords = ["词B", "词C"]
        doubao.applyResolvedTranscription(resolved)
        #expect(doubao.hotwords == ["词B", "词C"])

        var v25 = AppConfig()
        v25.hotwords = ["词A"]
        v25.asr.provider = .mimoV25
        var v25Resolved = v25.resolvedTranscription
        v25Resolved.hotwords = ["词D"]
        v25.applyResolvedTranscription(v25Resolved)
        #expect(v25.hotwords == ["词D"])
    }

    @Test func applyResolvedOnNonConsumersLeavesHotwordsUntouched() {
        var config = AppConfig()
        config.hotwords = ["词A"]
        config.asr.provider = .openaiCompatible
        var resolved = config.resolvedTranscription
        resolved.hotwords = ["不该写回"]
        config.applyResolvedTranscription(resolved)
        #expect(config.hotwords == ["词A"])

        var mimo7b = AppConfig()
        mimo7b.hotwords = ["词A"]
        mimo7b.asr.provider = .mimo7b
        var mimo7bResolved = mimo7b.resolvedTranscription
        mimo7bResolved.hotwords = ["不该写回"]
        mimo7b.applyResolvedTranscription(mimo7bResolved)
        #expect(mimo7b.hotwords == ["词A"])
    }

    @Test func switchingProviderNeverMutatesHotwordTable() {
        var config = AppConfig()
        config.hotwords = ["词A", "词B"]
        for provider in ASRProvider.allCases {
            config.asr.provider = provider
            _ = config.resolvedTranscription
            #expect(config.hotwords == ["词A", "词B"])
        }
    }
}
