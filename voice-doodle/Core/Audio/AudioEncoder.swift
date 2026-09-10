import AVFoundation
import Foundation
import os.log

nonisolated struct RecordedAudio: @unchecked Sendable {
    /// Already downsampled-while-recording to 16 kHz mono Float32.
    let buffers: [AVAudioPCMBuffer]
    let format: AVAudioFormat
    let duration: TimeInterval
}

nonisolated enum AudioEncoder {
    static let targetSampleRate: Double = 16_000

    static func targetFormat() -> AVAudioFormat? {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        )
    }

    static func encode(_ audio: RecordedAudio) throws -> URL {
        guard !audio.buffers.isEmpty else { throw VDError.emptyTranscript }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("record-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: targetSampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 48_000,
        ]
        do {
            let file = try AVAudioFile(
                forWriting: url,
                settings: settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
            for buffer in audio.buffers {
                try file.write(from: buffer)
            }
        } catch {
            Log.audio.error("encode failed: \(String(describing: error))")
            try? FileManager.default.removeItem(at: url)
            throw VDError.encodeFailed
        }
        return url
    }
}

extension RecordedAudio {
    /// Decodes an audio file (e.g. our AAC m4a) into the recorded-audio
    /// carrier — shared by the WAV re-encode path and Doubao's PCM fallback.
    static func read(from url: URL) throws -> RecordedAudio {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw VDError.encodeFailed
        }
        let format = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw VDError.emptyTranscript
        }
        do {
            try file.read(into: buffer)
        } catch {
            throw VDError.encodeFailed
        }
        return RecordedAudio(buffers: [buffer], format: format, duration: Double(frameCount) / format.sampleRate)
    }
}
