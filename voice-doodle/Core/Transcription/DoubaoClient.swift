import Darwin
import Foundation
import os.log

/// Byte-level codec for Volcengine OpenSpeech **V1** protocol (e.g. seedasr
/// 2.0). Frames are `[0x11, (type<<4)|flags, 0x00, 0x00] + payload` — type
/// lives in the HIGH nibble of byte1; the server rejects V3 framing.
nonisolated enum DoubaoFrame {
    /// V1 message types (shifted to high nibble when encoded).
    static let typeStart: UInt8 = 0x01    // full client request (JSON params)
    static let typeAudio: UInt8 = 0x02    // audio-only packet
    /// Flag: last packet from the client (finish).
    static let flagLastPacket: UInt8 = 0x02

    static func startFrame(json: Data) -> Data {
        frame(type: typeStart, flags: 0x00, payload: json)
    }

    static func audioFrame(pcm: Data) -> Data {
        frame(type: typeAudio, flags: 0x00, payload: pcm)
    }

    /// Finish = an empty audio-only frame with the last-packet flag.
    static func finishFrame() -> Data {
        frame(type: typeAudio, flags: flagLastPacket, payload: Data())
    }

    /// V1 client frame: 4-byte header, 4-byte big-endian payload length,
    /// then payload (server error "declared body size does not match" proved
    /// the length field is mandatory).
    private static func frame(type: UInt8, flags: UInt8, payload: Data) -> Data {
        var data = Data([0x11, (type << 4) | flags, 0x00, 0x00])
        var length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(payload)
        return data
    }

    /// Robust payload extraction: find the first `{` after the header region
    /// and take everything from there. Tolerates V1 (4-byte header) and V3
    /// (4-byte header + 8-byte event/length prefix) server frames alike.
    static func jsonPayload(from data: Data) -> Data? {
        guard data.count > 4 else { return nil }
        guard let braceIndex = data.firstIndex(of: UInt8(ascii: "{")),
              braceIndex > data.startIndex else { return nil }
        return data.subdata(in: braceIndex..<data.endIndex)
    }

    /// Low nibble of byte1 — the message-type-specific flags. V1 server frames
    /// lay out byte1 as `(type << 4) | flags`, mirroring the client encoding.
    static func serverFlags(from data: Data) -> UInt8? {
        guard data.count > 1 else { return nil }
        return data[data.index(data.startIndex, offsetBy: 1)] & 0x0f
    }

    /// Server-side counterpart of `flagLastPacket`: the result is complete and
    /// no further frames will follow on this connection.
    static func isLastPackage(_ data: Data) -> Bool {
        (serverFlags(from: data) ?? 0) & flagLastPacket != 0
    }
}

/// Server result JSON (lenient — field set varies by model edition).
nonisolated struct DoubaoResult: Decodable, Sendable {
    struct Result: Decodable {
        let text: String?
    }
    let code: Int?
    let message: String?
    let result: Result?
    let is_interim: Bool?
    let error: String?
}

/// Volcengine Doubao bigmodel ASR over WebSocket — one-shot. One call = one
/// WebSocket: connect → start → upload PCM → finish → read to last package.
/// config.baseURL = the block's wsURL, config.model its resourceID.
actor DoubaoClient {
    /// Hotword caps: nostream 5000 / streaming 100. Trimmed, deduped.
    static func cappedHotwords(_ words: [String], wsURL: URL) -> [String] {
        var seen = Set<String>()
        let cleaned = words
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .filter { seen.insert($0).inserted }
        let limit = wsURL.absoluteString.contains("_nostream") ? 5000 : 100
        guard cleaned.count > limit else { return cleaned }
        Log.asr.warning("hotwords \(cleaned.count) exceed cap \(limit); truncating")
        return Array(cleaned.prefix(limit))
    }

    /// Start-frame request-block builder — internal for unit pinning. Server
    /// defaults punc/ITN on, DDC off — all three flags written explicitly.
    /// Hotwords travel as `request.corpus.context`, a JSON-encoded *string*.
    static func startRequestBody(enablePunc: Bool, enableITN: Bool, enableDDC: Bool, hotwords: [String] = []) -> Data {
        struct HotwordPayload: Encodable {
            struct Word: Encodable { let word: String }
            let hotwords: [Word]
        }
        var request: [String: Any] = [
            "enable_punc": enablePunc,
            "enable_itn": enableITN,
            "enable_ddc": enableDDC,
            "show_utterances": true,
        ]
        if !hotwords.isEmpty,
           let contextData = try? JSONEncoder().encode(HotwordPayload(hotwords: hotwords.map { .init(word: $0) })),
           let context = String(data: contextData, encoding: .utf8) {
            request["corpus"] = ["context": context]
        }
        let frame: [String: Any] = [
            "user": ["uid": "voice-doodle"],
            "audio": ["format": "pcm", "rate": 16000, "bits": 16, "channel": 1],
            "request": request,
        ]
        return (try? JSONSerialization.data(withJSONObject: frame)) ?? Data()
    }

    func transcribe(pcm16: Data, config: TranscriptionConfig) async throws -> String {
        guard !config.apiKey.isEmpty else { throw VDError.apiNotConfigured }

        var request = URLRequest(url: config.baseURL, timeoutInterval: config.requestTimeout)
        request.setValue(config.apiKey, forHTTPHeaderField: "X-Api-Key")
        request.setValue(config.model, forHTTPHeaderField: "X-Api-Resource-Id")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Api-Connect-Id")

        let urlSession = URLSession(configuration: .ephemeral)
        defer { urlSession.invalidateAndCancel() }
        let socket = urlSession.webSocketTask(with: request)
        do {
            try await socket.open()
            Log.asr.info("doubao ws connected")
        } catch {
            Log.asr.error("doubao ws open failed: \(String(describing: error))")
            throw VDError.network("doubao ws 连接失败: \(error.localizedDescription)")
        }
        defer { socket.cancel(with: .goingAway, reason: nil) }

        // 1. start frame — V1 full-client-request JSON; auth travels in
        // headers. Text-post flags come from config (default all-true;
        // DDC = filler-word smoothing).
        let hotwords = Self.cappedHotwords(config.hotwords, wsURL: config.baseURL)
        let startJSON = Self.startRequestBody(
            enablePunc: config.doubaoEnablePunc,
            enableITN: config.doubaoEnableITN,
            enableDDC: config.doubaoEnableDDC,
            hotwords: hotwords
        )
        Log.asr.info("doubao transcribe: provider=doubao hotwords=\(hotwords.count) [\(hotwords.prefix(20).joined(separator: ","))]")
        Log.asr.info("doubao start frame: \(String(data: startJSON, encoding: .utf8)?.prefix(400) ?? "?")")
        do {
            try await socket.send(.data(DoubaoFrame.startFrame(json: startJSON)))
        } catch {
            Log.asr.error("doubao start frame send failed: \(String(describing: error))")
            throw VDError.network("doubao start 发送失败: \(error.localizedDescription)")
        }

        // 2. upload the whole blob in ~100 ms chunks
        let chunkSize = 3200   // 3200 bytes = 100 ms at 16 kHz mono s16le
        var offset = pcm16.startIndex
        while offset < pcm16.endIndex {
            try Task.checkCancellation()
            let end = pcm16.index(offset, offsetBy: chunkSize, limitedBy: pcm16.endIndex) ?? pcm16.endIndex
            try await socket.send(.data(DoubaoFrame.audioFrame(pcm: pcm16.subdata(in: offset..<end))))
            offset = end
        }

        // 3. finish — tells the server no more audio is coming
        try await socket.send(.data(DoubaoFrame.finishFrame()))

        // 4. read until the server flags its last package, the socket closes,
        //    or the idle deadline lapses. On this endpoint the text arrives
        //    once, on the terminal frame.
        var finalText = ""
        var deadline = Date().addingTimeInterval(config.requestTimeout)
        while Date() < deadline {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await socket.receive()
            } catch {
                if Task.isCancelled { throw CancellationError() }
                break   // closed after finish — treat as end of results
            }
            guard case .data(let data) = message else { continue }
            let typeByte = data.count > 1 ? data[data.index(data.startIndex, offsetBy: 1)] : 0
            guard let payload = DoubaoFrame.jsonPayload(from: data) else {
                Log.asr.error("doubao rx frame without JSON (type=0x\(String(typeByte, radix: 16)), \(data.count) bytes)")
                continue
            }
            guard let decoded = try? JSONDecoder().decode(DoubaoResult.self, from: payload) else {
                Log.asr.error("doubao rx undecodable JSON head=\(String(data: payload.prefix(120), encoding: .utf8) ?? "?")")
                continue
            }
            if let errorText = decoded.error, !errorText.isEmpty {
                Log.asr.error("doubao server error: \(errorText.prefix(300))")
                throw VDError.invalidResponse("doubao 错误: \(errorText.prefix(200))")
            }
            if let code = decoded.code, code != 0 {
                Log.asr.error("doubao server code=\(code) message=\(decoded.message ?? "?")")
                throw VDError.httpStatus(code, body: decoded.message)
            }
            if let text = decoded.result?.text, !text.isEmpty {
                finalText = text
                deadline = Date().addingTimeInterval(config.requestTimeout)   // alive → extend
            }
            if DoubaoFrame.isLastPackage(data) {
                Log.asr.info("doubao last package after \(finalText.count) chars")
                break
            }
        }

        let trimmed = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { throw VDError.emptyTranscript }
        return trimmed
    }
}

private extension URLSessionWebSocketTask {
    /// Waits for the WebSocket handshake to complete. A ping fired immediately
    /// after resume() races the async handshake and fails with "not connected".
    func open(timeout: TimeInterval = 10) async throws {
        resume()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            switch state {
            case .running:
                return
            case .completed, .canceling:
                throw error ?? URLError(.cannotConnectToHost)
            default:
                try await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        throw URLError(.timedOut)
    }
}
