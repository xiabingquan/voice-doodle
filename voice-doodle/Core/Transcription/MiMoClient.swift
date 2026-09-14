import Foundation
import os.log

/// MiMo-7B ASR client (Xiaomi mimo-v2.5-asr): OpenAI chat-completions shaped
/// — audio as a base64 data-URL in an `input_audio` block; wav/mp3 only.
/// One-shot: one request per WAV, full transcript in the response.
/// Auth is the platform `api-key` header. No system prompt, no hotwords,
/// no thinking parameter — the dedicated ASR model has none of them.
nonisolated struct MiMoClient: Sendable {
    var session: URLSession

    init(session: URLSession = OpenAIClient.makeSession()) {
        self.session = session
    }

    private struct RequestBody: Encodable {
        struct Content: Encodable {
            struct InputAudio: Encodable { let data: String }
            let type: String
            let input_audio: InputAudio
        }
        struct Message: Encodable { let role: String; let content: [Content] }
        struct ASROptions: Encodable { let language: String }
        let model: String
        let messages: [Message]
        var asr_options: ASROptions?
    }

    private struct FinalChunk: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { let content: String? }
            let message: Message?
        }
        let choices: [Choice]?
    }

    /// Transcribes a WAV blob in one request; returns the full transcript.
    func transcribe(wavData: Data, config: TranscriptionConfig) async throws -> String {
        guard config.isConfigured else { throw VDError.apiNotConfigured }
        // No implicit fallbacks: the active block's baseURL/model values are
        // used verbatim.
        let url = config.baseURL.appendingPathComponent("chat/completions")

        let dataURL = "data:audio/wav;base64," + wavData.base64EncodedString()
        var body = RequestBody(
            model: config.model,
            messages: [.init(role: "user", content: [.init(type: "input_audio", input_audio: .init(data: dataURL))])]
        )
        body.asr_options = .init(language: config.language)

        var request = URLRequest(url: url, timeoutInterval: config.requestTimeout)
        request.httpMethod = "POST"
        MiMoAuth.apply(to: &request, apiKey: config.apiKey)
        do {
            request.httpBody = try JSONEncoder().encode(body)
        } catch {
            throw VDError.invalidResponse("MiMo 请求编码失败")
        }
        return try await performOneShot(request)
    }

    private func performOneShot(_ request: URLRequest) async throws -> String {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw HTTPTransport.mapTransportError(error)
        }
        try Self.validate(response)
        guard let decoded = try? JSONDecoder().decode(FinalChunk.self, from: data),
              let text = decoded.choices?.first?.message?.content?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            throw VDError.invalidResponse("MiMo 响应缺少 content")
        }
        return text
    }

    private static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw VDError.invalidResponse("MiMo 响应不是 HTTP")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw VDError.httpStatus(http.statusCode, body: nil)
        }
    }
}

/// Shared Xiaomi open-platform auth: the `api-key` header (documented
/// primary), used by both MiMo-7B and MiMo-V2.5 clients.
enum MiMoAuth {
    static func apply(to request: inout URLRequest, apiKey: String) {
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "api-key")
    }
}
