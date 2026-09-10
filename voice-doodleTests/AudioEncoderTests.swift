import Testing
import AVFoundation
@testable import voice_doodle

struct AudioEncoderTests {
    @Test func sineRoundTrip() throws {
        let audio = try makeSineAudio(seconds: 1.0)
        let url = try AudioEncoder.encode(audio)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(url.pathExtension == "m4a")

        let file = try AVAudioFile(forReading: url)
        #expect(file.fileFormat.sampleRate == 16_000)
        #expect(file.fileFormat.channelCount == 1)
        // AAC adds encoder delay/padding; allow generous tolerance around 1s.
        let duration = Double(file.length) / file.fileFormat.sampleRate
        #expect(duration > 0.5 && duration < 1.5)
    }

    @Test func emptyBuffersThrow() {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let audio = RecordedAudio(buffers: [], format: format, duration: 0)
        #expect(throws: VDError.self) {
            _ = try AudioEncoder.encode(audio)
        }
    }
}
