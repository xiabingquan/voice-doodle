import AVFoundation
import Darwin
import Foundation
import os.log

/// dlopen-based binding to the bundled ten_vad.dylib binary (Apache-2.0,
/// Agora/TEN Framework), loaded from Resources at runtime — no build-time
/// linking; requires the disable-library-validation entitlement.
final class TENVad: @unchecked Sendable {
    private let lock = NSLock()
    private var handle: UnsafeMutableRawPointer?
    private var pending: [Int16] = []
    private let hopSize: Int

    private let createFn: @convention(c) (UnsafeMutablePointer<UnsafeMutableRawPointer?>?, Int, Float) -> Int32
    private let processFn: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<Int16>?, Int, UnsafeMutablePointer<Float>?, UnsafeMutablePointer<Int32>?) -> Int32
    private let destroyFn: @convention(c) (UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> Int32

    /// nil when the dylib cannot be loaded (wrong arch, missing resource…)
    /// — callers fall back to the RMS segmenter.
    init?(hopSize: Int = 256, threshold: Float = 0.5) {
        self.hopSize = hopSize
        guard let dylibURL = Bundle.main.url(forResource: "ten_vad", withExtension: "bin") else {
            Log.audio.error("ten_vad.bin not found in bundle")
            return nil
        }
        guard let lib = dlopen(dylibURL.path, RTLD_NOW) else {
            Log.audio.error("dlopen ten_vad failed: \(String(cString: dlerror()))")
            return nil
        }
        guard
            let createSym = dlsym(lib, "ten_vad_create"),
            let processSym = dlsym(lib, "ten_vad_process"),
            let destroySym = dlsym(lib, "ten_vad_destroy")
        else {
            Log.audio.error("ten_vad symbols missing")
            dlclose(lib)
            return nil
        }
        createFn = unsafeBitCast(createSym, to: (@convention(c) (UnsafeMutablePointer<UnsafeMutableRawPointer?>?, Int, Float) -> Int32).self)
        processFn = unsafeBitCast(processSym, to: (@convention(c) (UnsafeMutableRawPointer?, UnsafePointer<Int16>?, Int, UnsafeMutablePointer<Float>?, UnsafeMutablePointer<Int32>?) -> Int32).self)
        destroyFn = unsafeBitCast(destroySym, to: (@convention(c) (UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> Int32).self)

        var h: UnsafeMutableRawPointer?
        let status = createFn(&h, hopSize, threshold)
        guard status == 0, let h else {
            Log.audio.error("ten_vad_create failed: \(status)")
            return nil
        }
        handle = h
        Log.audio.info("TEN VAD loaded (hop \(hopSize), threshold \(threshold))")
    }

    deinit {
        var h: UnsafeMutableRawPointer? = handle
        _ = destroyFn(&h)
    }

    /// Feeds one converted 16 kHz float buffer; returns true when the most
    /// recent analysis hop inside it detected voice.
    func detectsVoice(in buffer: AVAudioPCMBuffer) -> Bool {
        guard let channel = buffer.floatChannelData?[0] else { return false }
        lock.lock()
        defer { lock.unlock() }
        let frames = Int(buffer.frameLength)
        for i in 0..<frames {
            let clamped = max(-1.0, min(1.0, Double(channel[i])))
            pending.append(Int16(clamped * 32767))
        }
        var voiceDetected = false
        while pending.count >= hopSize {
            let chunk = Array(pending.prefix(hopSize))
            pending.removeFirst(hopSize)
            var probability: Float = 0
            var flag: Int32 = 0
            let status = chunk.withUnsafeBufferPointer { ptr in
                processFn(handle, ptr.baseAddress, hopSize, &probability, &flag)
            }
            if status == 0, flag == 1 {
                voiceDetected = true
            }
        }
        return voiceDetected
    }

    /// Drops samples queued for the next analysis hop, so the tail of one
    /// segment (fewer than `hopSize` samples) cannot bleed into the next.
    /// The detector's own model state has no reset call in the C API.
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        pending.removeAll()
    }
}
