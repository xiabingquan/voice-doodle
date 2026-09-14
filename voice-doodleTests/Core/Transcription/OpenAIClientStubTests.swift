import Testing
import Foundation
@testable import voice_doodle

/// URLProtocol stub recording requests and returning canned responses.
/// Static state is shared — the suite must run serialized.
final class StubURLProtocol: BaseStubURLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, Data))?
    nonisolated(unsafe) static var lastRequest: URLRequest?
    nonisolated(unsafe) static var lastBody: Data?
    nonisolated(unsafe) static var requestCount = 0
    nonisolated(unsafe) static var failWith: Error?

    static func reset() {
        handler = nil
        lastRequest = nil
        lastBody = nil
        requestCount = 0
        failWith = nil
    }

    override func startLoading() {
        Self.requestCount += 1
        Self.lastRequest = request
        Self.lastBody = Self.drainBody(of: request)
        if let fail = Self.failWith {
            client?.urlProtocol(self, didFailWithError: fail)
            return
        }
        guard let handler = Self.handler, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        do {
            let (status, data) = try handler(request)
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
}

private func stubbedClient() -> OpenAIClient {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubURLProtocol.self]
    return OpenAIClient(session: URLSession(configuration: config))
}

private func testConfig() -> TranscriptionConfig {
    TranscriptionConfig(
        baseURL: URL(string: "https://api.example.com/v1")!,
        apiKey: "sk-test-1234567890",
        model: "whisper-1"
    )
}

private func wavLikeData() -> Data {
    Data(repeating: 0x11, count: 64)
}

@Suite(.serialized)
struct OpenAIClientStubTests {
    private func lastBodyString() -> String {
        String(data: StubURLProtocol.lastBody ?? Data(), encoding: .utf8) ?? ""
    }

    @Test func transcribeSuccessParsesText() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.handler = { _ in (200, Data(#"{"text":"你好世界"}"#.utf8)) }
        let client = stubbedClient()
        let text = try await client.transcribe(fileData: wavLikeData(), filename: "r.m4a", config: testConfig())
        #expect(text == "你好世界")

        let request = StubURLProtocol.lastRequest!
        #expect(request.url?.path.hasSuffix("/audio/transcriptions") == true)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test-1234567890")
        let body = lastBodyString()
        #expect(body.contains("name=\"language\"\r\n\r\nzh"))
        #expect(body.contains("name=\"model\"\r\n\r\nwhisper-1"))
        #expect(body.contains("name=\"response_format\"\r\n\r\njson"))
        #expect(body.contains("name=\"temperature\"\r\n\r\n0"))
        #expect(body.contains("audio/mp4"))
    }

    @Test func promptIncludedOnlyWhenNonEmpty() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.handler = { _ in (200, Data(#"{"text":"x"}"#.utf8)) }
        var config = testConfig()
        config.prompt = "普通话讨论"
        _ = try? await stubbedClient().transcribe(fileData: Data([0]), filename: "r.m4a", config: config)
        #expect(lastBodyString().contains("name=\"prompt\"\r\n\r\n普通话讨论"))
    }

    @Test func languageComesFromConfig() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.handler = { _ in (200, Data(#"{"text":"x"}"#.utf8)) }
        var config = testConfig()
        config.language = "en"
        _ = try? await stubbedClient().transcribe(fileData: Data([0]), filename: "r.m4a", config: config)
        #expect(lastBodyString().contains("name=\"language\"\r\n\r\nen"))
    }

    @Test func promptOmittedWhenEmpty() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.handler = { _ in (200, Data(#"{"text":"x"}"#.utf8)) }
        _ = try? await stubbedClient().transcribe(fileData: Data([0]), filename: "r.m4a", config: testConfig())
        #expect(!lastBodyString().contains("name=\"prompt\""))
    }

    @Test func status401MapsToError() async {
        StubURLProtocol.reset()
        StubURLProtocol.handler = { _ in (401, Data(#"{"error":{"message":"bad key"}}"#.utf8)) }
        await #expect(throws: VDError.self) {
            _ = try await stubbedClient().transcribe(fileData: Data([0]), filename: "r.m4a", config: testConfig())
        }
    }

    @Test func emptyTextThrowsEmptyTranscript() async {
        StubURLProtocol.reset()
        StubURLProtocol.handler = { _ in (200, Data(#"{"text":"   "}"#.utf8)) }
        do {
            _ = try await stubbedClient().transcribe(fileData: Data([0]), filename: "r.m4a", config: testConfig())
            Issue.record("expected emptyTranscript")
        } catch let error as VDError {
            #expect(error == .emptyTranscript)
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test func nonJSONThrowsInvalidResponse() async {
        StubURLProtocol.reset()
        StubURLProtocol.handler = { _ in (200, Data("not json".utf8)) }
        do {
            _ = try await stubbedClient().transcribe(fileData: Data([0]), filename: "r.m4a", config: testConfig())
            Issue.record("expected invalidResponse")
        } catch let error as VDError {
            guard case .invalidResponse = error else {
                Issue.record("expected invalidResponse, got \(error)")
                return
            }
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test func timeoutMapsToTimeout() async {
        StubURLProtocol.reset()
        StubURLProtocol.failWith = URLError(.timedOut)
        do {
            _ = try await stubbedClient().transcribe(fileData: Data([0]), filename: "r.m4a", config: testConfig())
            Issue.record("expected timeout")
        } catch let error as VDError {
            #expect(error == .timeout)
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test func missingKeyThrowsNotConfigured() async {
        let config = TranscriptionConfig(apiKey: "")
        do {
            _ = try await stubbedClient().transcribe(fileData: Data([0]), filename: "r.m4a", config: config)
            Issue.record("expected apiNotConfigured")
        } catch let error as VDError {
            #expect(error == .apiNotConfigured)
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test func baseURLJoiningHandlesTrailingSlashAndPath() {
        let withPath = URL(vdBase: "https://api.example.com/v1/")!
        #expect(OpenAIClient.transcribeURL(base: withPath).absoluteString == "https://api.example.com/v1/audio/transcriptions")
        let bare = URL(vdBase: "https://api.example.com")!
        #expect(OpenAIClient.transcribeURL(base: bare).absoluteString == "https://api.example.com/audio/transcriptions")
    }

    @Test func extraHeadersInjected() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.handler = { _ in (200, Data(#"{"text":"x"}"#.utf8)) }
        var config = testConfig()
        config.extraHeaders = [HTTPHeader(name: "X-Custom-Auth", value: "abc")]
        _ = try await stubbedClient().transcribe(fileData: Data([0]), filename: "r.m4a", config: config)
        #expect(StubURLProtocol.lastRequest!.value(forHTTPHeaderField: "X-Custom-Auth") == "abc")
    }
}
