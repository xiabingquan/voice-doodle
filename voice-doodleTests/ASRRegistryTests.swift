import Foundation
import Testing
@testable import voice_doodle

struct ASRRegistryTests {
    @Test func registryResolvesEachProvider() {
        #expect(ASRRegistry.backend(for: .openaiCompatible).id == .openaiCompatible)
        #expect(ASRRegistry.backend(for: .mimo).id == .mimo)
        #expect(ASRRegistry.backend(for: .doubao).id == .doubao)
    }

    @Test func registryExposesAllBackends() {
        let ids = ASRRegistry.all.map(\.id)
        #expect(ids.contains(.openaiCompatible))
        #expect(ids.contains(.mimo))
        #expect(ids.contains(.doubao))
    }

    /// Doubao consumes raw 16 kHz PCM and skips the AAC round-trip; the HTTP
    /// backends need a container, so they take the m4a. This is a shape
    /// question, not a streaming one — nothing streams any more.
    @Test func onlyDoubaoAcceptsRawPCM() {
        #expect(ASRRegistry.backend(for: .doubao).acceptsPCM == true)
        #expect(ASRRegistry.backend(for: .openaiCompatible).acceptsPCM == false)
        #expect(ASRRegistry.backend(for: .mimo).acceptsPCM == false)
    }

    /// Literal-pin suite for all built-in provider constants — every other
    /// file references ASRBuiltIns.
    @Test func builtInsCarryProbedValues() {
        #expect(ASRBuiltIns.openaiBaseURL.absoluteString == "https://api.openai.com/v1")
        #expect(ASRBuiltIns.openaiModel == "whisper-1")
        #expect(ASRBuiltIns.mimoBaseURL.absoluteString == "https://api.xiaomimimo.com/v1")
        #expect(ASRBuiltIns.mimoModel == "mimo-v2.5-asr")
        #expect(ASRBuiltIns.doubaoWsURL.absoluteString == "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_nostream")
        #expect(ASRBuiltIns.doubaoResourceID == "volc.seedasr.sauc.duration")
        // Struct defaults resolve to the same built-ins.
        let doubao = DoubaoConfig()
        #expect(doubao.wsURL == ASRBuiltIns.doubaoWsURL)
        #expect(doubao.resourceID == ASRBuiltIns.doubaoResourceID)
        let openai = OpenAICompatibleConfig()
        #expect(openai.baseURL == ASRBuiltIns.openaiBaseURL)
        #expect(openai.model == ASRBuiltIns.openaiModel)
        let mimo = MiMoConfig()
        #expect(mimo.baseURL == ASRBuiltIns.mimoBaseURL)
        #expect(mimo.model == ASRBuiltIns.mimoModel)
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
}
