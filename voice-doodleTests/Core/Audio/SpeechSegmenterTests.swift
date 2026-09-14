import Testing
import AVFoundation
@testable import voice_doodle

struct SpeechSegmenterTests {
    @Test func silenceAloneEmitsNothing() {
        let segmenter = SpeechSegmenter(sampleRate: 16_000)
        for _ in 0..<20 {
            #expect(segmenter.feed(makeTestBuffer(seconds: 0.1), rms: 0.001) == nil)
        }
        #expect(segmenter.flush() == nil)
    }

    @Test func speechFollowedByPauseEmitsSegment() {
        let segmenter = SpeechSegmenter(sampleRate: 16_000, minSilence: 0.6, minSpeech: 0.25)
        // 0.5s speech
        for _ in 0..<5 {
            #expect(segmenter.feed(makeTestBuffer(seconds: 0.1), rms: 0.05) == nil)
        }
        // 0.5s silence — not yet at threshold
        for _ in 0..<5 {
            #expect(segmenter.feed(makeTestBuffer(seconds: 0.1), rms: 0.001) == nil)
        }
        // 0.2s more silence crosses 0.6s → emit
        var emitted: RecordedAudio?
        for _ in 0..<2 {
            emitted = segmenter.feed(makeTestBuffer(seconds: 0.1), rms: 0.001) ?? emitted
        }
        #expect(emitted != nil)
        #expect(emitted!.duration > 1.0)   // speech + trailing silence
    }

    @Test func shortNoiseBelowMinSpeechDoesNotEmit() {
        let segmenter = SpeechSegmenter(sampleRate: 16_000, minSilence: 0.6, minSpeech: 0.25)
        #expect(segmenter.feed(makeTestBuffer(seconds: 0.1), rms: 0.05) == nil)   // 0.1s blip
        for _ in 0..<10 {
            #expect(segmenter.feed(makeTestBuffer(seconds: 0.1), rms: 0.001) == nil)
        }
        #expect(segmenter.flush() == nil)
    }

    @Test func flushEmitsInProgressDialogue() {
        let segmenter = SpeechSegmenter(sampleRate: 16_000)
        for _ in 0..<5 {
            _ = segmenter.feed(makeTestBuffer(seconds: 0.1), rms: 0.05)
        }
        let flushed = segmenter.flush()
        #expect(flushed != nil)
        #expect(flushed!.duration > 0.4)
        // State reset: subsequent silence emits nothing.
        #expect(segmenter.flush() == nil)
    }

    @Test func secondUtteranceStartsFreshSegment() {
        let segmenter = SpeechSegmenter(sampleRate: 16_000, minSilence: 0.6, minSpeech: 0.25)
        func utterance() -> RecordedAudio? {
            for _ in 0..<5 { _ = segmenter.feed(makeTestBuffer(seconds: 0.1), rms: 0.05) }
            var emitted: RecordedAudio?
            for _ in 0..<7 {
                emitted = segmenter.feed(makeTestBuffer(seconds: 0.1), rms: 0.001) ?? emitted
            }
            return emitted
        }
        #expect(utterance() != nil)
        #expect(utterance() != nil)
    }
}
