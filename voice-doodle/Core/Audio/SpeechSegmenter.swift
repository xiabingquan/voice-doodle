import AVFoundation
import Foundation
import os

/// Utterance segmenter: speech/silence from TEN VAD when available, else an
/// RMS threshold. A pause after speech emits a segment; flush() on release
/// emits in-progress speech.
final class SpeechSegmenter: @unchecked Sendable {
    private let lock = NSLock()
    private var current: [AVAudioPCMBuffer] = []
    private var currentDuration: TimeInterval = 0
    private var silenceDuration: TimeInterval = 0
    private var speechDuration: TimeInterval = 0
    private var speechActive = false
    private let sampleRate: Double
    private let vad: TENVad?
    /// Tuning observability: last VAD verdict and the
    /// per-hold cut index.
    private var lastDetect: Bool?
    private var cutIndex = 0

    // Tunables (v0 constants; move to settings when proven).
    private let rmsThreshold: Float
    private let minSilence: TimeInterval
    private let minSpeech: TimeInterval

    init(
        sampleRate: Double,
        vad: TENVad? = nil,
        rmsThreshold: Float = 0.012,      // ≈ -38 dBFS (fallback path only)
        minSilence: TimeInterval = 0.65,  // 0.4 trips on breath noise, 0.8 clips held vowels — midpoint chosen
        minSpeech: TimeInterval = 0.20
    ) {
        self.sampleRate = sampleRate
        self.vad = vad
        self.rmsThreshold = rmsThreshold
        self.minSilence = minSilence
        self.minSpeech = minSpeech
    }

    /// Feed one converted buffer. Returns a completed segment when a pause
    /// boundary is detected, nil otherwise. Order-preserving (single producer).
    func feed(_ buffer: AVAudioPCMBuffer, rms: Float) -> RecordedAudio? {
        let speaking = vad?.detectsVoice(in: buffer) ?? (rms >= rmsThreshold)
        lock.lock()
        defer { lock.unlock() }
        let frameDuration = Double(buffer.frameLength) / sampleRate
        current.append(buffer)
        currentDuration += frameDuration

        // Log only on VAD verdict flips (per-buffer logging would flood) —
        // flip density is what tuning looks at.
        if lastDetect != speaking {
            Log.audio.info("vad detect → \(speaking ? "voice" : "silence") (rms \(Log.fixed(Double(rms), 4)))")
            lastDetect = speaking
        }

        if speaking {
            speechDuration += frameDuration
            silenceDuration = 0
            if speechDuration >= minSpeech, !speechActive {
                speechActive = true
                Log.audio.info("vad speech onset (speech \(Log.fixed(self.speechDuration))s ≥ minSpeech \(Log.fixed(self.minSpeech))s)")
            }
            return nil
        }

        silenceDuration += frameDuration
        guard speechActive, silenceDuration >= minSilence else { return nil }
        return emitLocked(reason: "silence-cut")
    }

    /// End-of-session flush: any speech in progress becomes the last segment.
    func flush() -> RecordedAudio? {
        lock.lock()
        defer { lock.unlock() }
        guard speechActive, !current.isEmpty else {
            resetLocked()
            return nil
        }
        return emitLocked(reason: "release-flush")
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        resetLocked()
    }

    /// Cut reason is part of the log: silence-cut = pause boundary,
    /// release-flush = tail emitted on key release.
    private func emitLocked(reason: String) -> RecordedAudio? {
        guard !current.isEmpty, let format = AudioEncoder.targetFormat() else {
            resetLocked()
            return nil
        }
        cutIndex += 1
        Log.audio.info("segment #\(self.cutIndex) emit \(Log.fixed(self.currentDuration))s reason=\(reason) (minSilence \(Log.fixed(self.minSilence))s)")
        let segment = RecordedAudio(buffers: current, format: format, duration: currentDuration)
        resetLocked()
        return segment
    }

    private func resetLocked() {
        current = []
        currentDuration = 0
        silenceDuration = 0
        speechDuration = 0
        speechActive = false
        lastDetect = nil
        // cutIndex is never reset: it numbers cuts across the whole hold
        // (the segmenter is rebuilt per press anyway).
        vad?.reset()
    }
}
