import AVFoundation
import Foundation

/// WAV (PCM16) encoding for providers that don't accept AAC/m4a — MiMo ASR
/// only takes wav/mp3, while our pipeline produces AAC segments.
enum WAVEncoder {
    /// Encodes 16 kHz mono float buffers into a PCM16 WAV blob.
    static func wav(from audio: RecordedAudio) throws -> Data {
        let sampleRate = Int(audio.format.sampleRate)
        var samples: [Int16] = []
        samples.reserveCapacity(Int(audio.duration * audio.format.sampleRate) + 1024)
        for buffer in audio.buffers {
            guard let channel = buffer.floatChannelData?[0] else { continue }
            for i in 0..<Int(buffer.frameLength) {
                let clamped = max(-1.0, min(1.0, Double(channel[i])))
                samples.append(Int16(clamped * 32767))
            }
        }
        guard !samples.isEmpty else { throw VDError.emptyTranscript }
        return wavBlob(samples: samples, sampleRate: sampleRate)
    }

    /// Raw PCM16 samples without a WAV header — Doubao's WS protocol takes
    /// bare PCM inside its binary frames.
    static func pcm16Data(from audio: RecordedAudio) throws -> Data {
        var out = Data()
        for buffer in audio.buffers {
            out.append(pcm16Chunk(from: buffer))
        }
        guard !out.isEmpty else { throw VDError.emptyTranscript }
        return out
    }

    /// One converted buffer as raw s16le. Returns empty data when the buffer
    /// has no channel data — callers that need a non-empty result check.
    static func pcm16Chunk(from buffer: AVAudioPCMBuffer) -> Data {
        guard let channel = buffer.floatChannelData?[0] else { return Data() }
        let frames = Int(buffer.frameLength)
        var samples = [Int16](repeating: 0, count: frames)
        for i in 0..<frames {
            let clamped = max(-1.0, min(1.0, Double(channel[i])))
            samples[i] = Int16(clamped * 32767)
        }
        return samples.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// Reads an encoded audio file (e.g. our AAC m4a) and re-encodes to WAV.
    static func wav(fromFileAt url: URL) throws -> Data {
        try wav(from: RecordedAudio.read(from: url))
    }

    private static func wavBlob(samples: [Int16], sampleRate: Int) -> Data {
        let dataSize = samples.count * 2
        var data = Data()
        data.reserveCapacity(44 + dataSize)

        func ascii(_ s: String) { data.append(s.data(using: .ascii)!) }
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }

        ascii("RIFF")
        u32(UInt32(36 + dataSize))
        ascii("WAVE")
        ascii("fmt ")
        u32(16)                 // PCM header size
        u16(1)                  // PCM format
        u16(1)                  // mono
        u32(UInt32(sampleRate))
        u32(UInt32(sampleRate * 2))   // byte rate
        u16(2)                  // block align
        u16(16)                 // bits per sample
        ascii("data")
        u32(UInt32(dataSize))
        for s in samples { u16(UInt16(bitPattern: s)) }
        return data
    }
}
