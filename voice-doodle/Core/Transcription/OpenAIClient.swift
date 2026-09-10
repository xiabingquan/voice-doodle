import Foundation

/// Thin HTTP layer for the OpenAI-compatible transcription protocol
/// (reference implementation; see ASRRegistry for backend routing).
nonisolated struct OpenAIClient: Sendable {
    var session: URLSession

    init(session: URLSession = OpenAIClient.makeSession()) {
        self.session = session
    }

    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }

    static func transcribeURL(base: URL) -> URL {
        base.appendingPathComponent("audio/transcriptions")
    }

    // MARK: - Transcribe

    func transcribe(fileData: Data, filename: String, config: TranscriptionConfig) async throws -> String {
        guard config.isConfigured else { throw VDError.apiNotConfigured }
        let url = Self.transcribeURL(base: config.baseURL)

        var multipart = MultipartFormData()
        multipart.addFile(name: "file", filename: filename, mimeType: "audio/mp4", data: fileData)
        multipart.addField(name: "model", value: config.model)
        if !config.prompt.isEmpty {
            multipart.addField(name: "prompt", value: config.prompt)
        }
        multipart.addField(name: "language", value: config.language.isEmpty ? "zh" : config.language)
        multipart.addField(name: "response_format", value: "json")
        multipart.addField(name: "temperature", value: "0")

        var request = URLRequest(url: url, timeoutInterval: config.requestTimeout)
        request.httpMethod = "POST"
        request.applyAuth(apiKey: config.apiKey, extraHeaders: config.extraHeaders)
        request.setValue(multipart.contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = multipart.build()

        let data = try await perform(request)
        return try Self.parseTranscript(data)
    }

    static func parseTranscript(_ data: Data) throws -> String {
        struct Response: Decodable { let text: String? }
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data) else {
            throw VDError.invalidResponse("非 JSON 或缺少 text 字段")
        }
        guard let text = decoded.text else {
            throw VDError.invalidResponse("缺少 text 字段")
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { throw VDError.emptyTranscript }
        return trimmed
    }

    // MARK: - Transport

    private func perform(_ request: URLRequest) async throws -> Data {
        try Task.checkCancellation()
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw HTTPTransport.mapTransportError(error)
        }
        try Task.checkCancellation()

        guard let http = response as? HTTPURLResponse else {
            throw VDError.invalidResponse("非 HTTP 响应")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data.prefix(500), encoding: .utf8)
            throw VDError.httpStatus(http.statusCode, body: body)
        }
        // Cap is enforced by reading at most 1 MB from oversized bodies.
        if data.count > 1_000_000 {
            throw VDError.invalidResponse("响应超过 1 MB")
        }
        return data
    }
}
