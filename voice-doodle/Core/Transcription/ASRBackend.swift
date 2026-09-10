import AVFoundation
import Foundation
import os.log

// MARK: - Audio envelope

/// The audio handed to a backend: `.file` = AAC m4a (OpenAI compatible,
/// MiMo); `.pcm` = raw 16 kHz mono s16le (Doubao's native WebSocket input).
nonisolated enum ASRAudio: Sendable {
    case file(URL)
    case pcm(Data)
}

// MARK: - Backends

/// One ASR implementation. Adding a backend = implement this + register in
/// `ASRRegistry` + one enum case. One-shot only — a complete segment in,
/// its full transcript out.
protocol ASRBackend: Sendable {
    var id: ASRProvider { get }
    /// Whether the backend can consume `ASRAudio.pcm` directly. Backends that
    /// leave this false always get a m4a file.
    var acceptsPCM: Bool { get }
    func transcribe(audio: ASRAudio, config: TranscriptionConfig) async throws -> String
}

extension ASRBackend {
    var acceptsPCM: Bool { false }
}

/// Volcengine Doubao bigmodel ASR — WebSocket, raw 16k PCM (zero
/// transcoding), X-Api-Key auth. One-shot: one WebSocket per segment, text
/// returned after FINISH (`/sauc/bigmodel_nostream`).
struct DoubaoBackend: ASRBackend {
    let id: ASRProvider = .doubao
    private let client = DoubaoClient()

    var acceptsPCM: Bool { true }

    func transcribe(audio: ASRAudio, config: TranscriptionConfig) async throws -> String {
        switch audio {
        case .pcm(let data):
            return try await client.transcribe(pcm16: data, config: config)
        case .file(let url):
            return try await client.transcribe(pcm16: try Self.pcm16(decodingM4AAt: url), config: config)
        }
    }

    /// Fallback when a m4a arrives (the file tier). The segment tier feeds
    /// `.pcm` and skips this.
    private static func pcm16(decodingM4AAt url: URL) throws -> Data {
        try WAVEncoder.pcm16Data(from: RecordedAudio.read(from: url))
    }
}

/// The registry: the single place a new backend plugs in.
enum ASRRegistry {
    private static let backends: [any ASRBackend] = [
        OpenAICompatibleBackend(),
        MiMoBackend(),
        DoubaoBackend(),
    ]

    /// Registry safety net: an unregistered provider id falls back to the
    /// openai-compatible backend instead of crashing a release build.
    static func backend(for provider: ASRProvider) -> any ASRBackend {
        if let match = backends.first(where: { $0.id == provider }) {
            return match
        }
        Log.asr.warning("no backend registered for provider \(provider.rawValue); falling back to openai-compatible")
        return backends[0]
    }

    /// Dashboard / diagnostics.
    static var all: [any ASRBackend] { backends }
}

// MARK: - Concrete backends

/// OpenAI-compatible `/audio/transcriptions` (OpenAI, OpenRouter, Groq…).
/// One multipart POST per segment; the response carries the whole transcript.
struct OpenAICompatibleBackend: ASRBackend {
    let id: ASRProvider = .openaiCompatible
    private let client = OpenAIClient()

    func transcribe(audio: ASRAudio, config: TranscriptionConfig) async throws -> String {
        guard case .file(let url) = audio else {
            throw VDError.encodeFailed
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw VDError.encodeFailed
        }
        return try await client.transcribe(
            fileData: data, filename: url.lastPathComponent, config: config
        )
    }
}

/// Xiaomi MiMo ASR — chat-completions protocol, wav-only. One request per
/// segment; the audio is base64 in an `input_audio` content block.
struct MiMoBackend: ASRBackend {
    let id: ASRProvider = .mimo
    private let client = MiMoClient()

    func transcribe(audio: ASRAudio, config: TranscriptionConfig) async throws -> String {
        guard case .file(let url) = audio else {
            throw VDError.encodeFailed
        }
        let wav = try WAVEncoder.wav(fromFileAt: url)
        return try await client.transcribe(wavData: wav, config: config)
    }
}
