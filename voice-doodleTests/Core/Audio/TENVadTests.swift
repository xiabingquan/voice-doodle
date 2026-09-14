import Testing
import AVFoundation
@testable import voice_doodle

struct TENVadTests {
    @Test func loadsAndClassifiesSilence() throws {
        let vad = try #require(TENVad(), "ten_vad.dylib failed to load from bundle")
        let buffer = makeTestBuffer(seconds: 0.064)   // 1024 frames of zeros = silence
        // Four hops of 256 silence samples — no voice expected.
        for _ in 0..<4 {
            #expect(vad.detectsVoice(in: buffer) == false)
        }
    }
}
