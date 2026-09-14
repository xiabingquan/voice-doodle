import Foundation
import os.log

/// MiMo-V2.5 multimodal ASR client (Xiaomi mimo-v2.5): chat-completions with
/// a config-driven system prompt and thinking disabled. Hotwords are appended
/// to the prompt here — never as an API parameter. One-shot per WAV.
nonisolated struct MiMoV25Client: Sendable {
    var session: URLSession
    /// Prompt-side hotword cap — human limit only; far below model context.
    static let hotwordLimit = 1000

    init(session: URLSession = OpenAIClient.makeSession()) {
        self.session = session
    }

    private struct Content: Encodable {
        struct InputAudio: Encodable { let data: String }
        let type: String
        let input_audio: InputAudio
    }

    private enum Message: Encodable {
        case system(String)
        case userAudio(dataURL: String)

        private enum CodingKeys: String, CodingKey { case role, content }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .system(let text):
                try c.encode("system", forKey: .role)
                try c.encode(text, forKey: .content)
            case .userAudio(let dataURL):
                try c.encode("user", forKey: .role)
                try c.encode(
                    [Content(type: "input_audio", input_audio: .init(data: dataURL))],
                    forKey: .content
                )
            }
        }
    }

    private struct RequestBody: Encodable {
        struct Thinking: Encodable { let type = "disabled" }
        let model: String
        let messages: [Message]
        let thinking: Thinking
    }

    private struct FinalChunk: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { let content: String? }
            let message: Message?
        }
        let choices: [Choice]?
    }

    /// System prompt = config prompt (empty → built-in default) plus a
    /// hotword section when the table is non-empty.
    static func systemPrompt(base: String, hotwords: [String]) -> String {
        var prompt = base.trimmingCharacters(in: .whitespacesAndNewlines)
        if prompt.isEmpty {
            prompt = ASRBuiltIns.mimoV25DefaultPrompt
        }
        guard let section = hotwordSection(from: hotwords) else { return prompt }
        return prompt + "\n" + section
    }

    /// Hotword correction section, or nil when nothing survives cleaning.
    static func hotwordSection(from words: [String]) -> String? {
        var seen = Set<String>()
        let cleaned = words
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .filter { seen.insert($0).inserted }
        guard !cleaned.isEmpty else { return nil }
        var capped = cleaned
        if cleaned.count > hotwordLimit {
            Log.asr.warning("hotwords \(cleaned.count) exceed prompt cap \(hotwordLimit); truncating")
            capped = Array(cleaned.prefix(hotwordLimit))
        }
        return "若出现下列词条的误听，请修正为正确写法：" + capped.joined(separator: "，")
    }

    /// Transcribes a WAV blob in one request; returns the transcript text.
    func transcribe(wavData: Data, config: TranscriptionConfig) async throws -> String {
        guard config.isConfigured else { throw VDError.apiNotConfigured }
        let url = config.baseURL.appendingPathComponent("chat/completions")

        if config.mimoV25Prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Log.asr.info("mimo-v25 prompt empty; using built-in default")
        }
        let system = Self.systemPrompt(base: config.mimoV25Prompt, hotwords: config.hotwords)

        let dataURL = "data:audio/wav;base64," + wavData.base64EncodedString()
        let body = RequestBody(
            model: config.model,
            messages: [.system(system), .userAudio(dataURL: dataURL)],
            thinking: .init()
        )

        var request = URLRequest(url: url, timeoutInterval: config.requestTimeout)
        request.httpMethod = "POST"
        MiMoAuth.apply(to: &request, apiKey: config.apiKey)
        do {
            request.httpBody = try JSONEncoder().encode(body)
        } catch {
            throw VDError.invalidResponse("MiMo-V2.5 请求编码失败")
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
              let raw = decoded.choices?.first?.message?.content else {
            throw VDError.invalidResponse("MiMo-V2.5 响应缺少 content")
        }
        if let chunk = try? JSONDecoder().decode(ReasoningProbe.self, from: data),
           let reasoning = chunk.choices?.first?.message?.reasoning_content,
           !reasoning.isEmpty {
            Log.asr.warning("mimo-v2.5 returned reasoning_content (\(reasoning.count)B); thinking flag may be ignored")
        }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { throw VDError.emptyTranscript }
        return text
    }

    private struct ReasoningProbe: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { let reasoning_content: String? }
            let message: Message?
        }
        let choices: [Choice]?
    }

    private static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw VDError.invalidResponse("MiMo-V2.5 响应不是 HTTP")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw VDError.httpStatus(http.statusCode, body: nil)
        }
    }
}
