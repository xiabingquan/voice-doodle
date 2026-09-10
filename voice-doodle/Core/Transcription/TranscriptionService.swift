import AVFoundation
import Foundation
import os.log

protocol Transcribing: AnyObject {
    func transcribe(fileURL: URL, config: TranscriptionConfig) async throws -> String
    /// Segment tier: the caller hands over in-memory PCM and the service picks
    /// the transport — raw PCM for backends that take it, m4a otherwise.
    func transcribe(segment: RecordedAudio, config: TranscriptionConfig) async throws -> String
    /// One-shot connectivity test: synthesized short silence through the
    /// current backend's real protocol. Never probes /models and never
    /// depends on a bundled sample file.
    func transcriptionTest(config: TranscriptionConfig) async -> TestOutcome
}

extension Transcribing {
    /// Default segment tier: encode to m4a and delegate to the file tier.
    /// Doubao's own backend overrides the transport by answering
    /// `acceptsPCM`, which the service consults before encoding.
    func transcribe(segment: RecordedAudio, config: TranscriptionConfig) async throws -> String {
        let url = try AudioEncoder.encode(segment)
        return try await transcribe(fileURL: url, config: config)
    }
}

/// Thin service: picks the backend from the registry and owns file lifecycle
/// + logging. One-shot only — a segment goes in, its full transcript comes
/// out.
actor TranscriptionService: Transcribing {
    /// Deletes the temp file only on success; on failure the file is kept for
    /// inspection/retry tooling.
    func transcribe(fileURL: URL, config: TranscriptionConfig) async throws -> String {
        try await run(audio: .file(fileURL), config: config)
    }

    func transcribe(segment: RecordedAudio, config: TranscriptionConfig) async throws -> String {
        let backend = ASRRegistry.backend(for: config.provider)
        // Doubao takes raw 16k PCM and skips the AAC round-trip; the HTTP
        // backends need a container, so they get the m4a.
        let audio: ASRAudio
        if backend.acceptsPCM {
            audio = .pcm(try WAVEncoder.pcm16Data(from: segment))
        } else {
            audio = .file(try AudioEncoder.encode(segment))
        }
        return try await run(audio: audio, config: config)
    }

    private func run(audio: ASRAudio, config: TranscriptionConfig) async throws -> String {
        let backend = ASRRegistry.backend(for: config.provider)
        let start = Date()
        do {
            let text = try await backend.transcribe(audio: audio, config: config)
            if case .file(let url) = audio {
                try? FileManager.default.removeItem(at: url)
            }
            let elapsed = Date().timeIntervalSince(start)
            Log.asr.info("\(backend.id.rawValue) transcribed in \(Log.fixed(elapsed))s → \(text.count) chars: \(String(text.prefix(60)))")
            return text
        } catch let error as VDError {
            var message = "\(backend.id.rawValue) failed: \(error.shortTitle)"
            if case .file(let url) = audio {
                message += "; keeping \(url.lastPathComponent)"
            }
            message += " | \(error.debugCaseDescription)"
            if let body = error.debugBodyValue {
                message += " | body: \(String(body.prefix(1_000)))"
            }
            Log.asr.error(message)
            throw error
        } catch {
            Log.asr.error("\(backend.id.rawValue) failed: \(Log.describe(error))")
            throw VDError.network(Log.describe(error))
        }
    }

    /// Synthesises ~0.5 s of silence (16 kHz mono) and sends one request
    /// through the current provider's real protocol — auth, endpoint and
    /// transport verified in one shot.
    func transcriptionTest(config: TranscriptionConfig) async -> TestOutcome {
        guard config.isConfigured else { return .failure(.apiNotConfigured) }
        guard let silence = Self.silenceSegment() else { return .failure(.encodeFailed) }
        do {
            _ = try await transcribe(segment: silence, config: config)
            return .success(detail: "连接成功")
        } catch let error as VDError {
            if case .emptyTranscript = error {
                return .success(detail: "连接成功")
            }
            return .failure(error)
        } catch {
            return .failure(.network(Log.describe(error)))
        }
    }

    private static func silenceSegment(seconds: Double = 0.5, sampleRate: Double = 16_000) -> RecordedAudio? {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ),
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(seconds * sampleRate)) else {
            return nil
        }
        buffer.frameLength = buffer.frameCapacity
        let byteCount = Int(buffer.frameLength) * MemoryLayout<Float>.size
        if let samples = buffer.floatChannelData?[0] {
            memset(samples, 0, byteCount)
        }
        return RecordedAudio(buffers: [buffer], format: format, duration: seconds)
    }
}
