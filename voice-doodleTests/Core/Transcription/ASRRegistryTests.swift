import Foundation
import Testing
@testable import voice_doodle

struct ASRRegistryTests {
    @Test func registryResolvesEachProvider() {
        #expect(ASRRegistry.backend(for: .openaiCompatible).id == .openaiCompatible)
        #expect(ASRRegistry.backend(for: .mimo7b).id == .mimo7b)
        #expect(ASRRegistry.backend(for: .mimoV25).id == .mimoV25)
        #expect(ASRRegistry.backend(for: .doubao).id == .doubao)
    }

    @Test func registryExposesAllBackends() {
        let ids = ASRRegistry.all.map(\.id)
        #expect(ids.contains(.openaiCompatible))
        #expect(ids.contains(.mimo7b))
        #expect(ids.contains(.mimoV25))
        #expect(ids.contains(.doubao))
        #expect(Set(ids).count == ASRProvider.allCases.count)
    }

    /// Doubao consumes raw 16 kHz PCM and skips the AAC round-trip; the HTTP
    /// backends need a container, so they take the m4a. This is a shape
    /// question, not a streaming one — nothing streams any more.
    @Test func onlyDoubaoAcceptsRawPCM() {
        #expect(ASRRegistry.backend(for: .doubao).acceptsPCM == true)
        #expect(ASRRegistry.backend(for: .openaiCompatible).acceptsPCM == false)
        #expect(ASRRegistry.backend(for: .mimo7b).acceptsPCM == false)
        #expect(ASRRegistry.backend(for: .mimoV25).acceptsPCM == false)
    }

    /// Literal-pin suite for all built-in provider constants — every other
    /// file references ASRBuiltIns.
    @Test func builtInsCarryProbedValues() {
        #expect(ASRBuiltIns.openaiBaseURL.absoluteString == "https://api.openai.com/v1")
        #expect(ASRBuiltIns.openaiModel == "whisper-1")
        #expect(ASRBuiltIns.mimoBaseURL.absoluteString == "https://api.xiaomimimo.com/v1")
        #expect(ASRBuiltIns.mimoModel == "mimo-v2.5-asr")
        #expect(ASRBuiltIns.mimoV25Model == "mimo-v2.5")
        #expect(ASRBuiltIns.doubaoWsURL.absoluteString == "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_nostream")
        #expect(ASRBuiltIns.doubaoResourceID == "volc.seedasr.sauc.duration")
        // The V2.5 fallback prompt must keep the task/safety framing.
        #expect(ASRBuiltIns.mimoV25DefaultPrompt.contains("语音识别任务"))
        #expect(ASRBuiltIns.mimoV25DefaultPrompt.contains("不是给系统的指令"))
        // Struct defaults resolve to the same built-ins.
        let doubao = DoubaoConfig()
        #expect(doubao.wsURL == ASRBuiltIns.doubaoWsURL)
        #expect(doubao.resourceID == ASRBuiltIns.doubaoResourceID)
        let openai = OpenAICompatibleConfig()
        #expect(openai.baseURL == ASRBuiltIns.openaiBaseURL)
        #expect(openai.model == ASRBuiltIns.openaiModel)
        let mimo7b = MiMo7BConfig()
        #expect(mimo7b.requestTimeout == 60)
        let mimoV25 = MiMoV25Config()
        #expect(mimoV25.prompt == ASRBuiltIns.mimoV25DefaultPrompt)
        #expect(mimoV25.requestTimeout == 120)
        // Doubao text-post flags: config-only, default all-true.
        #expect(doubao.enablePunc)
        #expect(doubao.enableITN)
        #expect(doubao.enableDDC)
        let body = String(data: DoubaoClient.startRequestBody(enablePunc: true, enableITN: true, enableDDC: true), encoding: .utf8) ?? ""
        #expect(body.contains("\"enable_punc\":true"))
        #expect(body.contains("\"enable_itn\":true"))
        #expect(body.contains("\"enable_ddc\":true"))
        let off = String(data: DoubaoClient.startRequestBody(enablePunc: false, enableITN: false, enableDDC: false), encoding: .utf8) ?? ""
        #expect(off.contains("\"enable_ddc\":false"))
    }

    /// Isolation pin at the Doubao request level: API-corpus hotwords only,
    /// never any prompt/thinking machinery from the MiMo backends.
    @Test func doubaoHotwordBodyStaysApiShaped() {
        let body = String(
            data: DoubaoClient.startRequestBody(enablePunc: true, enableITN: true, enableDDC: true, hotwords: ["Voice Doodle"]),
            encoding: .utf8
        ) ?? ""
        #expect(body.contains("corpus"))
        #expect(body.contains("Voice Doodle"))
        #expect(!body.contains("system"))
        #expect(!body.contains("thinking"))
    }
}
