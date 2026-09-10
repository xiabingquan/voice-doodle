import AVFoundation
import Foundation
@testable import voice_doodle

// MARK: - Audio fixtures (shared across suites)

/// 16 kHz mono float32 — the pipeline's native carrier format.
func makeTestFormat(sampleRate: Double = 16_000) -> AVAudioFormat {
    AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
}

/// Constant-filled buffer; `fill == 0` produces silence.
func makeTestBuffer(seconds: Double, sampleRate: Double = 16_000, fill: Float = 0) -> AVAudioPCMBuffer {
    let format = makeTestFormat(sampleRate: sampleRate)
    let frames = AVAudioFrameCount(max(1, seconds * sampleRate))
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    if fill != 0, let channel = buffer.floatChannelData?[0] {
        for i in 0..<Int(frames) { channel[i] = fill }
    }
    return buffer
}

/// RecordedAudio wrapping a constant-filled buffer.
func makeTestSegment(duration: Double, fill: Float = 0.5, sampleRate: Double = 16_000) -> RecordedAudio {
    let format = makeTestFormat(sampleRate: sampleRate)
    return RecordedAudio(
        buffers: [makeTestBuffer(seconds: duration, sampleRate: sampleRate, fill: fill)],
        format: format,
        duration: duration
    )
}

/// Sine-wave RecordedAudio for encoder round-trips.
func makeSineAudio(seconds: Double, sampleRate: Double = 16_000, frequency: Double = 440) throws -> RecordedAudio {
    let format = makeTestFormat(sampleRate: sampleRate)
    let totalFrames = AVAudioFrameCount(seconds * sampleRate)
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: totalFrames) else {
        throw VDError.audioEngine("buffer")
    }
    buffer.frameLength = totalFrames
    let channel = buffer.floatChannelData![0]
    for i in 0..<Int(totalFrames) {
        channel[i] = Float(sin(2 * Double.pi * frequency * Double(i) / sampleRate)) * 0.5
    }
    return RecordedAudio(buffers: [buffer], format: format, duration: seconds)
}

// MARK: - URLProtocol stub base

/// Shared stream-draining base for per-suite URLProtocol stubs. Each suite
/// keeps its own subclass so static state stays suite-local (suites run
/// .serialized; merging statics would race across suites).
class BaseStubURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    /// URLSession converts httpBody to httpBodyStream when going through
    /// URLProtocol — drain whichever form is present.
    static func drainBody(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
