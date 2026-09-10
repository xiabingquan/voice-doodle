import AVFoundation
import Foundation
import os.log

protocol AudioRecording: AnyObject {
    /// Starts capture; returns the VAD-cut utterance-segment stream, which
    /// finishes on stop/cancel.
    func start() async throws -> AsyncStream<RecordedAudio>
    /// Stops capture, flushes any in-progress speech as a final segment, finishes the stream.
    func stop() async throws
    /// Discards capture without emitting a final segment, finishes the stream.
    func cancel() async
}

/// Lock-protected storage shared between the audio tap's serial queue and the actor.
private nonisolated final class CaptureBox: @unchecked Sendable {
    let meter = LevelMeter()
}

/// Launch-sequence / TCC hygiene: init must NOT touch AVAudioEngine or the
/// input device — early access locks TCC into "access until you quit". The
/// engine is built lazily in start(), after Permissions.requestMicIfNeeded().
actor AudioRecorder: AudioRecording {
    private var engine: AVAudioEngine?
    private let box = CaptureBox()
    private var segmentContinuation: AsyncStream<RecordedAudio>.Continuation?
    private var segmenter: SpeechSegmenter?
    /// Bumped by every successful start(). stop()/cancel() re-check it after
    /// each suspension: an in-flight teardown must not nil out the NEW
    /// session's segmenter/continuation (Swift cancellation is cooperative).
    private var generation = 0
    /// Bumped at every start() entry — the newest start owns the recorder.
    /// A superseded in-flight start tears down its own engine and exits.
    private var startEpoch = 0

    func start() async throws -> AsyncStream<RecordedAudio> {
        startEpoch += 1
        let myStart = startEpoch
        // A live engine here is a leaked leftover from an earlier session's
        // in-flight start — newest start wins: tear it down and proceed.
        if let stale = engine {
            Log.audio.warning("start found leaked engine from an earlier start; tearing it down")
            stale.inputNode.removeTap(onBus: 0)
            stale.stop()
            self.engine = nil
            segmenter = nil
            segmentContinuation?.finish()
            segmentContinuation = nil
        }
        guard await Permissions.requestMicIfNeeded() else {
            throw VDError.micDenied
        }
        // Last cancellable point BEFORE any audio state exists: past here the
        // engine must be built to completion, or cancellation leaks a live
        // AVAudioEngine and wedges every later start().
        try Task.checkCancellation()
        guard myStart == startEpoch else { throw CancellationError() }

        let engine = AVAudioEngine()
        // Publish immediately: stop()/cancel() read this property and must
        // find the engine even while we are suspended in setup.
        self.engine = engine
        do {
            // activate() is the single place that bumps `generation`, on
            // success — that one bump lets a concurrent stop()/cancel() tell
            // "teardown raced a start still in flight" from "live session".
            return try await activate(engine: engine, myStart: myStart)
        } catch {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            if self.engine === engine { self.engine = nil }
            throw error
        }
    }

    /// Everything in start() after the engine exists. Kept separate so the
    /// caller can publish `self.engine` first and unwind it on any throw.
    /// Returns the segment stream; on return `generation` has been bumped.
    private func activate(engine: AVAudioEngine, myStart: Int) async throws -> AsyncStream<RecordedAudio> {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else {
            throw VDError.audioEngine("无可用输入设备")
        }
        guard let targetFormat = AudioEncoder.targetFormat(),
              let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw VDError.audioEngine("无法创建 16 kHz 转换器")
        }

        box.meter.reset()
        let segmenter = SpeechSegmenter(
            sampleRate: AudioEncoder.targetSampleRate,
            vad: TENVad()
        )
        self.segmenter = segmenter

        var segmentContinuation: AsyncStream<RecordedAudio>.Continuation?
        let segmentStream = AsyncStream<RecordedAudio>(bufferingPolicy: .unbounded) {
            segmentContinuation = $0
        }
        self.segmentContinuation = segmentContinuation

        // Newest start owns the device: a start superseded during setup must
        // not install a tap or start the engine.
        guard myStart == startEpoch else {
            segmenter.reset()
            self.segmenter = nil
            self.segmentContinuation?.finish()
            self.segmentContinuation = nil
            if self.engine === engine { self.engine = nil }
            throw CancellationError()
        }

        let box = self.box
        let segmentContinuationRef = segmentContinuation
        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { buffer, _ in
            guard let converted = Self.convert(buffer, using: converter) else { return }
            let rms = Self.rms(of: converted)
            box.meter.push(rms)
            if let segment = segmenter.feed(converted, rms: rms) {
                segmentContinuationRef?.yield(segment)
            }
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw VDError.audioEngine(error.localizedDescription)
        }
        guard myStart == startEpoch else {
            // Superseded while starting the device: tear down so the newest
            // start owns it uncontended.
            input.removeTap(onBus: 0)
            engine.stop()
            if self.engine === engine { self.engine = nil }
            throw CancellationError()
        }
        generation += 1
        Log.audio.info("recording started (input \(Log.fixed(inputFormat.sampleRate, 0)) Hz, TEN VAD segments)")
        return segmentStream
    }

    /// Stops capture and flushes any in-progress speech as the final
    /// segment, then finishes both streams. Idempotent — a stop after a
    /// teardown is a no-op.
    func stop() async throws {
        guard let engine else { return }
        let myGeneration = generation
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
        guard generation == myGeneration else { return }
        if let segment = segmenter?.flush() {
            segmentContinuation?.yield(segment)
            Log.audio.info("flushed final segment (\(Log.fixed(segment.duration))s)")
        }
        segmentContinuation?.finish()
        segmentContinuation = nil
        segmenter = nil
        Log.audio.info("recording stopped")
    }

    func cancel() async {
        let myGeneration = generation
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            self.engine = nil
        }
        guard generation == myGeneration else { return }
        segmenter?.reset()
        segmenter = nil
        segmentContinuation?.finish()
        segmentContinuation = nil
        Log.audio.info("recording cancelled")
    }

    /// Nonisolated: LevelMeter is lock-protected, safe to read from the HUD timer.
    nonisolated func levelSnapshot(count: Int) -> [Float] {
        box.meter.snapshot(count: count)
    }

    // MARK: - Tap helpers (pure, nonisolated)

    private nonisolated static func convert(_ input: AVAudioPCMBuffer, using converter: AVAudioConverter) -> AVAudioPCMBuffer? {
        let ratio = converter.outputFormat.sampleRate / converter.inputFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity) else {
            return nil
        }
        var consumed = false
        var failure: NSError?
        let status = converter.convert(to: output, error: &failure) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return input
        }
        guard status != .error, failure == nil, output.frameLength > 0 else { return nil }
        return output
    }

    private nonisolated static func rms(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData?[0] else { return 0 }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<frames {
            let sample = channel[i]
            sum += sample * sample
        }
        return sqrt(sum / Float(frames))
    }
}
