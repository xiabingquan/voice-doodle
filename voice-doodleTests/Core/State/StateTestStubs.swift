import Testing
import AVFoundation
@testable import voice_doodle

// Shared stubs for SessionStateMachine suites.
final class StubRecorder: AudioRecording, @unchecked Sendable {
    private(set) var started = false
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var cancelCount = 0
    private(set) var staleStopCount = 0
    private(set) var staleCancelCount = 0
    private(set) var cancelledDuringStart = 0
    /// Healthy mic by default; flip false to simulate TCC-fed zero buffers.
    var sawInputSignal = true
    var startError: VDError?
    /// First start only: suspends before returning, simulating the real
    /// recorder's in-flight start window across a fast press-release.
    var firstStartDelayNanos: UInt64 = 0
    /// When set, stop() suspends before finishing — simulates the real
    /// recorder's teardown window where a re-press can interleave.
    var stopDelayNanos: UInt64 = 0
    /// When true, stop() parks at a gate until releaseStopGate() — holds a
    /// stop in flight across a deterministic restart window. Parks even
    /// under Task.cancel, like the real recorder's actor bodies.
    var holdStopUntilGate = false
    /// True while stop() is between its delay/gate and finishing the stream.
    private(set) var stopInFlight = false
    private var stopGate: CheckedContinuation<Void, Never>?
    private var continuation: AsyncStream<RecordedAudio>.Continuation?
    /// Generation issued by the latest successful start(); stop/cancel with
    /// any other value are ignored — mirrors AudioRecorder's contract.
    private var generation = 0

    func start() async throws -> (stream: AsyncStream<RecordedAudio>, generation: Int) {
        started = true
        startCount += 1
        if startCount == 1, firstStartDelayNanos > 0 {
            try? await Task.sleep(nanoseconds: firstStartDelayNanos)
            if Task.isCancelled {
                cancelledDuringStart += 1
                throw CancellationError()
            }
        }
        if let startError { throw startError }
        generation += 1
        var cont: AsyncStream<RecordedAudio>.Continuation?
        let stream = AsyncStream<RecordedAudio>(bufferingPolicy: .unbounded) { cont = $0 }
        continuation = cont
        return (stream, generation)
    }

    func stop(generation: Int) async throws {
        stopCount += 1
        // Issuance check: a stop for a superseded session is a no-op.
        guard generation == self.generation else {
            staleStopCount += 1
            return
        }
        if holdStopUntilGate {
            stopInFlight = true
            await withCheckedContinuation { stopGate = $0 }
            stopInFlight = false
            guard generation == self.generation else {
                staleStopCount += 1
                return
            }
        } else if stopDelayNanos > 0 {
            stopInFlight = true
            try? await Task.sleep(nanoseconds: stopDelayNanos)
            stopInFlight = false
            // Re-check after suspension: a start() during the window owns
            // the stream now — never finish it from under the new session.
            guard generation == self.generation else {
                staleStopCount += 1
                return
            }
        }
        continuation?.finish()
    }

    func releaseStopGate() {
        stopGate?.resume()
        stopGate = nil
    }

    func cancel(generation: Int) async {
        cancelCount += 1
        guard generation == self.generation else {
            staleCancelCount += 1
            return
        }
        continuation?.finish()
    }

    func yieldSegment(duration: Double = 1.0) {
        continuation?.yield(makeTestSegment(duration: duration))
    }
}

final class StubTranscriber: Transcribing, @unchecked Sendable {
    var results: [Result<String, VDError>] = []
    var delayNanos: UInt64 = 0
    private(set) var callCount = 0

    func transcribe(fileURL: URL, config: TranscriptionConfig) async throws -> String {
        if delayNanos > 0 { try? await Task.sleep(nanoseconds: delayNanos) }
        let index = callCount
        callCount += 1
        let result = results.indices.contains(index) ? results[index] : .success("段文\(index + 1)")
        switch result {
        case .success(let text): return text
        case .failure(let error): throw error
        }
    }

    func transcriptionTest(config: TranscriptionConfig) async -> TestOutcome { .failure(.apiNotConfigured) }
}

final class StubInserter: TextInserting, @unchecked Sendable {
    private(set) var insertedTexts: [String] = []
    var insertError: VDError?
    var isSynthesizingInput = false

    func insert(_ text: String) async throws {
        if let insertError { throw insertError }
        insertedTexts.append(text)
    }

    private(set) var sendReturnCount = 0
    func sendReturn() async { sendReturnCount += 1 }
}

@MainActor
func makeMachine(
    recorder: StubRecorder,
    transcriber: StubTranscriber,
    inserter: StubInserter
) -> (SessionStateMachine, Date) {
    let start = Date(timeIntervalSince1970: 1_000_000)
    let machine = SessionStateMachine(
        recorder: recorder,
        transcriber: transcriber,
        inserter: inserter,
        config: TranscriptionConfig(apiKey: "sk-test")
    )
    machine.now = { start }
    return (machine, start)
}

@MainActor
func waitUntil(_ timeout: TimeInterval = 2.0, _ condition: @MainActor () -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline {
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
}
