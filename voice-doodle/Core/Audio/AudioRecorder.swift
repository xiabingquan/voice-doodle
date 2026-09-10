import AVFoundation
import Foundation
import os.log

protocol AudioRecording: AnyObject {
    /// True once any buffer with non-zero samples arrived this session —
    /// all-zero capture means the device/TCC path is feeding silence.
    var sawInputSignal: Bool { get }
    /// Starts capture; returns the VAD-cut utterance-segment stream plus the
    /// generation this session owns — pass it back on stop/cancel.
    func start() async throws -> (stream: AsyncStream<RecordedAudio>, generation: Int)
    /// Stops capture, flushes any in-progress speech as a final segment,
    /// finishes the stream. Ignored when `generation` is not the live one.
    func stop(generation: Int) async throws
    /// Discards capture without emitting a final segment, finishes the
    /// stream. Ignored when `generation` is not the live one.
    func cancel(generation: Int) async
}

/// Lock-protected storage shared between the audio tap's serial queue and the actor.
private nonisolated final class CaptureBox: @unchecked Sendable {
    let meter = LevelMeter()
    var sawSignal = false
}

/// Launch-sequence / TCC hygiene: init must NOT touch AVAudioEngine or the
/// input device — early access locks TCC into "access until you quit". The
/// engine is built lazily in start(), after Permissions.requestMicIfNeeded().
actor AudioRecorder: AudioRecording {
    private var engine: AVAudioEngine?
    private let box = CaptureBox()
    var sawInputSignal: Bool { box.sawSignal }
    private var segmentContinuation: AsyncStream<RecordedAudio>.Continuation?
    private var segmenter: SpeechSegmenter?
    /// Bumped by every successful start(). Callers receive the value from
    /// start() and pass it back on stop/cancel; a mismatched generation
    /// means the call was issued for a superseded session — ignored.
    private var generation = 0
    /// Bumped at every start() entry — the newest start owns the recorder.
    /// A superseded in-flight start tears down its own engine and exits.
    private var startEpoch = 0

    func start() async throws -> (stream: AsyncStream<RecordedAudio>, generation: Int) {
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
            // success — start returns it so callers can guard their own
            // stop/cancel against newer sessions.
            let stream = try await activate(engine: engine, myStart: myStart)
            return (stream, generation)
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
        box.sawSignal = false
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
            if rms > 0 { box.sawSignal = true }
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
    /// segment, then finishes both streams. Ignored when `generation` is not
    /// the live session's — a stale stop must never touch a newer engine.
    func stop(generation: Int) async throws {
        guard generation == self.generation else {
            Log.audio.info("stale stop ignored (gen \(generation) != \(self.generation))")
            return
        }
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
        if let segment = segmenter?.flush() {
            segmentContinuation?.yield(segment)
            Log.audio.info("flushed final segment (\(Log.fixed(segment.duration))s)")
        }
        segmentContinuation?.finish()
        segmentContinuation = nil
        segmenter = nil
        Log.audio.info("recording stopped")
    }

    func cancel(generation: Int) async {
        guard generation == self.generation else {
            Log.audio.info("stale cancel ignored (gen \(generation) != \(self.generation))")
            return
        }
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            self.engine = nil
        }
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
