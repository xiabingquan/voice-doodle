import AVFoundation
import Foundation
import Testing
@testable import voice_doodle

struct WAVEncoderTests {
    @Test func encodesValidPCM16WAV() throws {
        let audio = try makeSineAudio(seconds: 0.1)
        let wav = try WAVEncoder.wav(from: audio)
        #expect(String(data: wav.prefix(4), encoding: .ascii) == "RIFF")
        #expect(String(data: wav.subdata(in: 8..<12), encoding: .ascii) == "WAVE")
        #expect(wav.count == 44 + 1600 * 2)   // header + PCM16 mono
    }
}
