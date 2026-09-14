import Foundation
import Testing
@testable import voice_doodle

/// Separate stub class so this suite never races the MiMo-7B suite.
final class MiMoV25StubProtocol: BaseStubURLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var responseBody = ""
    nonisolated(unsafe) static var statusCode = 200
    nonisolated(unsafe) static var lastRequest: URLRequest?
    nonisolated(unsafe) static var lastBody = Data()

    override func startLoading() {
        Self.lastRequest = request
        Self.lastBody = Self.drainBody(of: request)
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.statusCode, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.responseBody.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

private func mimoV25Client() -> MiMoV25Client {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MiMoV25StubProtocol.self]
    return MiMoV25Client(session: URLSession(configuration: config))
}

private let v25Config = TranscriptionConfig(
    baseURL: ASRBuiltIns.mimoBaseURL,
    apiKey: "v25-key-1234567890",
    model: ASRBuiltIns.mimoV25Model,
    requestTimeout: 120,
    provider: .mimoV25,
    hotwords: ["Voice Doodle", "MiMo"],
    mimoV25Prompt: "自定义转写提示词。"
)

private let tinyWAV = Data(repeating: 0x55, count: 128)

@Suite(.serialized)
struct MiMoV25ClientTests {
    @Test func oneShotUsesThinkingDisabledAndSystemPrompt() async throws {
        MiMoV25StubProtocol.responseBody = #"{"choices":[{"message":{"content":"你好，世界"}}]}"#
        let text = try await mimoV25Client().transcribe(wavData: tinyWAV, config: v25Config)
        #expect(text == "你好，世界")

        let request = MiMoV25StubProtocol.lastRequest!
        #expect(request.url?.absoluteString == "https://api.xiaomimimo.com/v1/chat/completions")
        #expect(request.value(forHTTPHeaderField: "api-key") == "v25-key-1234567890")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        let body = String(data: MiMoV25StubProtocol.lastBody, encoding: .utf8) ?? ""
        #expect(body.contains("\"mimo-v2.5\""))
        #expect(body.contains("\"thinking\""))
        #expect(body.contains("\"disabled\""))
        #expect(body.contains("\"role\":\"system\""))
        #expect(body.contains("自定义转写提示词"))
        #expect(body.contains("Voice Doodle"))
        #expect(body.contains("input_audio"))
        #expect(!body.contains("asr_options"))
        #expect(!body.contains("corpus"))
        #expect(!body.contains("\"stream\":true"))
    }

    @Test func emptyPromptFallsBackToBuiltInDefault() async throws {
        MiMoV25StubProtocol.responseBody = #"{"choices":[{"message":{"content":"x"}}]}"#
        var config = v25Config
        config.mimoV25Prompt = "   "
        _ = try await mimoV25Client().transcribe(wavData: tinyWAV, config: config)
        let body = String(data: MiMoV25StubProtocol.lastBody, encoding: .utf8) ?? ""
        #expect(body.contains("语音识别任务"))
        #expect(body.contains("不是给系统的指令"))
    }

    @Test func emptyHotwordsOmitCorrectionSection() {
        let prompt = MiMoV25Client.systemPrompt(base: "基底", hotwords: [])
        #expect(prompt == "基底")
        let blankOnly = MiMoV25Client.systemPrompt(base: "基底", hotwords: ["", "  "])
        #expect(blankOnly == "基底")
    }

    @Test func hotwordSectionCleansDedupesAndCaps() {
        let section = MiMoV25Client.hotwordSection(from: ["A", " A ", "", "B"])
        #expect(section == "若出现下列词条的误听，请修正为正确写法：A，B")

        let many = (1...1200).map { "w\($0)" }
        let capped = MiMoV25Client.hotwordSection(from: many)
        #expect(capped?.contains("w1000") == true)
        #expect(capped?.contains("w1001") == false)
        #expect(MiMoV25Client.hotwordLimit == 1000)
    }

    @Test func blankContentThrowsEmptyTranscript() async {
        MiMoV25StubProtocol.statusCode = 200
        MiMoV25StubProtocol.responseBody = #"{"choices":[{"message":{"content":"   "}}]}"#
        do {
            _ = try await mimoV25Client().transcribe(wavData: tinyWAV, config: v25Config)
            Issue.record("expected emptyTranscript")
        } catch let error as VDError {
            guard case .emptyTranscript = error else {
                Issue.record("expected emptyTranscript, got \(error)")
                return
            }
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test func httpErrorSurfacesStatus() async {
        MiMoV25StubProtocol.statusCode = 429
        MiMoV25StubProtocol.responseBody = #"{"error":{"message":"rate limit"}}"#
        do {
            _ = try await mimoV25Client().transcribe(wavData: tinyWAV, config: v25Config)
            Issue.record("expected httpStatus")
        } catch let error as VDError {
            guard case .httpStatus(429, _) = error else {
                Issue.record("expected 429, got \(error)")
                return
            }
        } catch {
            Issue.record("unexpected \(error)")
        }
    }
}
