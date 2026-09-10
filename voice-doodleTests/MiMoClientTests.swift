import Foundation
import Testing
@testable import voice_doodle

/// Separate stub class so this suite never races the other URLProtocol suites.
final class MiMoStubProtocol: BaseStubURLProtocol, @unchecked Sendable {
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

private func mimoClient() -> MiMoClient {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MiMoStubProtocol.self]
    return MiMoClient(session: URLSession(configuration: config))
}

/// Fixture config built from the built-in constants — distinct-literal
/// override coverage stays in customModelFromConfigIsUsed.
private let mimoConfig = TranscriptionConfig(
    baseURL: ASRBuiltIns.mimoBaseURL,
    apiKey: "mimo-key-1234567890",
    model: ASRBuiltIns.mimoModel,
    provider: .mimo
)

private let tinyWAV = Data(repeating: 0x55, count: 128)

@Suite(.serialized)
struct MiMoClientTests {
    @Test func oneShotParsesChatCompletion() async throws {
        MiMoStubProtocol.responseBody = #"{"choices":[{"message":{"content":"你好，世界"}}]}"#
        let text = try await mimoClient().transcribe(wavData: tinyWAV, config: mimoConfig)
        #expect(text == "你好，世界")

        let request = MiMoStubProtocol.lastRequest!
        #expect(request.url?.absoluteString == "https://api.xiaomimimo.com/v1/chat/completions")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer mimo-key-1234567890")
        let body = String(data: MiMoStubProtocol.lastBody, encoding: .utf8) ?? ""
        #expect(body.contains("\"mimo-v2.5-asr\""))
        #expect(body.contains("input_audio"))
        #expect(body.contains("base64,"))
        #expect(body.contains("audio"))
        #expect(body.contains("\"language\":\"zh\""))
        #expect(!body.contains("\"stream\":true"))
    }

    @Test func customModelFromConfigIsUsed() async throws {
        MiMoStubProtocol.responseBody = #"{"choices":[{"message":{"content":"x"}}]}"#
        var config = mimoConfig
        config.model = "mimo-custom-asr"
        _ = try? await mimoClient().transcribe(wavData: tinyWAV, config: config)
        let body = String(data: MiMoStubProtocol.lastBody, encoding: .utf8) ?? ""
        #expect(body.contains("\"mimo-custom-asr\""))
    }

    @Test func httpErrorSurfacesStatus() async {
        MiMoStubProtocol.statusCode = 401
        MiMoStubProtocol.responseBody = #"{"error":{"message":"bad key"}}"#
        do {
            _ = try await mimoClient().transcribe(wavData: tinyWAV, config: mimoConfig)
            Issue.record("expected httpStatus")
        } catch let error as VDError {
            guard case .httpStatus(401, _) = error else {
                Issue.record("expected 401, got \(error)")
                return
            }
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test func missingContentThrowsInvalidResponse() async {
        MiMoStubProtocol.statusCode = 200
        MiMoStubProtocol.responseBody = #"{"choices":[]}"#
        do {
            _ = try await mimoClient().transcribe(wavData: tinyWAV, config: mimoConfig)
            Issue.record("expected invalidResponse")
        } catch let error as VDError {
            guard case .invalidResponse = error else {
                Issue.record("expected invalidResponse, got \(error)")
                return
            }
        } catch {
            Issue.record("unexpected \(error)")
        }
    }
}
