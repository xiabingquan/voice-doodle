import Testing
import AVFoundation
@testable import voice_doodle

// MARK: - Stubs

private final class StubRecorder: AudioRecording, @unchecked Sendable {
    private(set) var started = false
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var cancelCount = 0
    private(set) var cancelledDuringStart = 0
    var startError: VDError?
    /// First start only: suspends before returning, simulating the real
    /// recorder's in-flight start window across a fast press-release.
    var firstStartDelayNanos: UInt64 = 0
    /// When set, stop() suspends before finishing — simulates the real
    /// recorder's teardown window where a re-press can interleave.
    var stopDelayNanos: UInt64 = 0
    /// True while stop() is between its delay and finishing the stream.
    private(set) var stopInFlight = false
    private var continuation: AsyncStream<RecordedAudio>.Continuation?
    /// Bumped by every start(); stop() re-checks it after its suspension so a
    /// stale stop never finishes the NEW session's stream.
    private var generation = 0

    func start() async throws -> AsyncStream<RecordedAudio> {
        started = true
        startCount += 1
        if startCount == 1, firstStartDelayNanos > 0 {
            try? await Task.sleep(nanoseconds: firstStartDelayNanos)
            if Task.isCancelled {
                cancelledDuringStart += 1
                throw CancellationError()
            }
        }
        generation += 1
        if let startError { throw startError }
        var cont: AsyncStream<RecordedAudio>.Continuation?
        let stream = AsyncStream<RecordedAudio>(bufferingPolicy: .unbounded) { cont = $0 }
        continuation = cont
        return stream
    }

    func stop() async throws {
        stopCount += 1
        let captured = generation
        if stopDelayNanos > 0 {
            stopInFlight = true
            try? await Task.sleep(nanoseconds: stopDelayNanos)
            stopInFlight = false
            // Mirrors the real recorder's generation guard: a start() that
            // landed during our suspension owns the stream now — never finish
            // it from under the new session.
            guard captured == generation else { return }
        }
        continuation?.finish()
    }

    func cancel() async {
        cancelCount += 1
        continuation?.finish()
    }

    func yieldSegment(duration: Double = 1.0) {
        continuation?.yield(makeTestSegment(duration: duration))
    }
}

private final class StubTranscriber: Transcribing, @unchecked Sendable {
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

private final class StubInserter: TextInserting, @unchecked Sendable {
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
private func makeMachine(
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
private func waitUntil(_ timeout: TimeInterval = 2.0, _ condition: @MainActor () -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline {
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
}

// MARK: - Tests

/// Per-test limit so a task left running surfaces as a failure in one minute
/// instead of hanging the whole suite — these tests await `waitForPendingWork`
/// directly, which has no built-in bound.
@Suite(.timeLimit(.minutes(1)))
struct StateMachineTests {
    @Test @MainActor func segmentsInsertWhileHolding() async {
        let recorder = StubRecorder()
        let transcriber = StubTranscriber()
        let inserter = StubInserter()
        let (machine, _) = makeMachine(recorder: recorder, transcriber: transcriber, inserter: inserter)

        machine.handleTriggerDown()
        await waitUntil { recorder.started }

        recorder.yieldSegment(duration: 1.0)
        // Insertion must happen BEFORE release — that is the whole point.
        await waitUntil { inserter.insertedTexts.count == 1 }
        #expect(inserter.insertedTexts == ["段文1"])
        #expect(machine.state == .recording(startedAt: machine.now()))

        machine.handleTriggerUp()
        await machine.waitForPendingWork()
        #expect(machine.state == .idle)
        #expect(machine.outcome == .success)
    }

    @Test @MainActor func multipleSegmentsInsertInOrder() async {
        let recorder = StubRecorder()
        let transcriber = StubTranscriber()
        let inserter = StubInserter()
        let (machine, _) = makeMachine(recorder: recorder, transcriber: transcriber, inserter: inserter)

        machine.handleTriggerDown()
        await waitUntil { recorder.started }
        recorder.yieldSegment(duration: 1.0)
        await waitUntil { inserter.insertedTexts.count == 1 }
        recorder.yieldSegment(duration: 1.2)
        await waitUntil { inserter.insertedTexts.count == 2 }

        machine.handleTriggerUp()
        await machine.waitForPendingWork()
        #expect(inserter.insertedTexts == ["段文1", "段文2"])
        #expect(machine.outcome == .success)
    }

    @Test @MainActor func releaseWithoutSpeechInsertsNothing() async {
        let recorder = StubRecorder()
        let inserter = StubInserter()
        let (machine, _) = makeMachine(recorder: recorder, transcriber: StubTranscriber(), inserter: inserter)

        machine.handleTriggerDown()
        await waitUntil { recorder.started }
        machine.handleTriggerUp()
        await machine.waitForPendingWork()

        #expect(inserter.insertedTexts.isEmpty)
        #expect(machine.state == .idle)
        #expect(recorder.stopCount == 1)
    }

    @Test @MainActor func transcribeFailureRecordsErrorAndContinues() async {
        let recorder = StubRecorder()
        let transcriber = StubTranscriber()
        transcriber.results = [.failure(.timeout), .success("第二段")]
        let inserter = StubInserter()
        let (machine, _) = makeMachine(recorder: recorder, transcriber: transcriber, inserter: inserter)

        machine.handleTriggerDown()
        await waitUntil { recorder.started }
        recorder.yieldSegment()
        await waitUntil { transcriber.callCount == 1 }
        recorder.yieldSegment()
        await waitUntil { inserter.insertedTexts.count == 1 }

        machine.handleTriggerUp()
        await machine.waitForPendingWork()
        #expect(inserter.insertedTexts == ["第二段"])
        #expect(machine.outcome == .success)   // one segment succeeded
    }

    @Test @MainActor func allSegmentsFailReportsFailureOutcome() async {
        let recorder = StubRecorder()
        let transcriber = StubTranscriber()
        transcriber.results = [.failure(.timeout)]
        let inserter = StubInserter()
        let (machine, _) = makeMachine(recorder: recorder, transcriber: transcriber, inserter: inserter)

        machine.handleTriggerDown()
        await waitUntil { recorder.started }
        recorder.yieldSegment()
        await waitUntil { transcriber.callCount == 1 }
        machine.handleTriggerUp()
        await machine.waitForPendingWork()

        #expect(inserter.insertedTexts.isEmpty)
        #expect(machine.outcome == .failure(.timeout))
    }

    @Test @MainActor func recorderStartFailureReturnsToIdle() async {
        let recorder = StubRecorder()
        recorder.startError = .micDenied
        let (machine, _) = makeMachine(recorder: recorder, transcriber: StubTranscriber(), inserter: StubInserter())

        machine.handleTriggerDown()
        await machine.waitForPendingWork()
        #expect(machine.state == .idle)
        #expect(machine.outcome == .failure(.micDenied))
    }

    @Test @MainActor func durationLimitEndsSessionLikeRelease() async {
        let recorder = StubRecorder()
        let inserter = StubInserter()
        let (machine, _) = makeMachine(recorder: recorder, transcriber: StubTranscriber(), inserter: inserter)

        machine.handleTriggerDown()
        await waitUntil { recorder.started }
        recorder.yieldSegment()
        await waitUntil { inserter.insertedTexts.count == 1 }
        machine.handleDurationLimit()
        await machine.waitForPendingWork()

        #expect(recorder.stopCount == 1)
        #expect(machine.state == .idle)
    }

    @Test @MainActor func readinessLossDisablesAndRestoreEnables() async {
        let (machine, _) = makeMachine(
            recorder: StubRecorder(), transcriber: StubTranscriber(), inserter: StubInserter()
        )
        machine.applyReadiness(false, reason: .accessibilityDenied)
        #expect(machine.state == .disabled(reason: .accessibilityDenied))
        machine.applyReadiness(true, reason: nil)
        #expect(machine.state == .idle)
    }

    /// Approved fix (pre-v0.0.1): while already disabled, a changed readiness
    /// reason must refresh the `.disabled(reason:)` payload — previously the
    /// stale reason persisted silently.
    @Test @MainActor func readinessReasonRefreshesWhileDisabled() {
        let (machine, _) = makeMachine(
            recorder: StubRecorder(), transcriber: StubTranscriber(), inserter: StubInserter()
        )
        machine.applyReadiness(false, reason: .micDenied)
        #expect(machine.state == .disabled(reason: .micDenied))
        machine.applyReadiness(false, reason: .apiNotConfigured)
        #expect(machine.state == .disabled(reason: .apiNotConfigured))
        // Same reason again → still disabled, no churn requirement beyond that.
        machine.applyReadiness(false, reason: .apiNotConfigured)
        #expect(machine.state == .disabled(reason: .apiNotConfigured))
    }

    @Test @MainActor func releaseDrainsInFlightSegment() async {
        let recorder = StubRecorder()
        let transcriber = StubTranscriber()
        transcriber.delayNanos = 300_000_000   // slow transcription
        let inserter = StubInserter()
        let (machine, _) = makeMachine(recorder: recorder, transcriber: transcriber, inserter: inserter)

        machine.handleTriggerDown()
        await waitUntil { recorder.started }
        recorder.yieldSegment(duration: 1.0)
        try? await Task.sleep(nanoseconds: 100_000_000)   // let it start
        machine.handleTriggerUp()                          // bounded drain
        await machine.waitForPendingWork()

        // Whatever the user actually said completes after release…
        #expect(inserter.insertedTexts == ["段文1"])
        #expect(machine.state == .idle)
        // …and nothing enters the pipeline after the stream finished.
        recorder.yieldSegment(duration: 1.0)               // no-op: stream closed
        try? await Task.sleep(nanoseconds: 400_000_000)
        #expect(inserter.insertedTexts == ["段文1"])
    }

    @Test @MainActor func insertFailureStillCompletesSession() async {
        let recorder = StubRecorder()
        let transcriber = StubTranscriber()
        let inserter = StubInserter()
        inserter.insertError = .accessibilityDenied
        let (machine, _) = makeMachine(recorder: recorder, transcriber: transcriber, inserter: inserter)

        machine.handleTriggerDown()
        await waitUntil { recorder.started }
        recorder.yieldSegment()
        await waitUntil { transcriber.callCount == 1 }
        machine.handleTriggerUp()
        await machine.waitForPendingWork()

        #expect(inserter.insertedTexts.isEmpty)
        #expect(machine.state == .idle)
        #expect(machine.outcome == .failure(.accessibilityDenied))
    }

    // MARK: - User-activity cancellation

    @Test @MainActor func userActivityDuringTranscribingCancelsPendingInserts() async {
        let recorder = StubRecorder()
        let transcriber = StubTranscriber()
        transcriber.delayNanos = 400_000_000   // slow transcription
        let inserter = StubInserter()
        let (machine, start) = makeMachine(recorder: recorder, transcriber: transcriber, inserter: inserter)

        machine.handleTriggerDown()
        await waitUntil { recorder.started }
        recorder.yieldSegment(duration: 1.0)
        try? await Task.sleep(nanoseconds: 100_000_000)   // let it start
        machine.handleTriggerUp()
        #expect(machine.state == .transcribing(startedAt: start))

        machine.handleUserActivity()
        #expect(machine.state == .idle)
        #expect(machine.outcome == .none)
        await machine.waitForPendingWork()
        try? await Task.sleep(nanoseconds: 500_000_000)   // let the cancelled task settle
        #expect(inserter.insertedTexts.isEmpty)           // nothing inserted after the click
    }

    @Test @MainActor func userActivityWhileIdleOrRecordingIsNoOp() async {
        let recorder = StubRecorder()
        let inserter = StubInserter()
        let (machine, start) = makeMachine(recorder: recorder, transcriber: StubTranscriber(), inserter: inserter)

        machine.handleUserActivity()
        #expect(machine.state == .idle)

        machine.handleTriggerDown()
        await waitUntil { recorder.started }
        machine.handleUserActivity()
        #expect(machine.state == .recording(startedAt: start))   // holding ≠ after release
        machine.handleTriggerUp()
        await machine.waitForPendingWork()
    }

    @Test @MainActor func syntheticInputIsExemptFromActivityCancel() async {
        let recorder = StubRecorder()
        let transcriber = StubTranscriber()
        transcriber.delayNanos = 400_000_000
        let inserter = StubInserter()
        inserter.isSynthesizingInput = true
        let (machine, start) = makeMachine(recorder: recorder, transcriber: transcriber, inserter: inserter)

        machine.handleTriggerDown()
        await waitUntil { recorder.started }
        recorder.yieldSegment(duration: 1.0)
        try? await Task.sleep(nanoseconds: 100_000_000)
        machine.handleTriggerUp()
        #expect(machine.state == .transcribing(startedAt: start))

        machine.handleUserActivity()   // our own ⌘V — must not cancel
        #expect(machine.state == .transcribing(startedAt: start))
        await machine.waitForPendingWork()
        #expect(inserter.insertedTexts == ["段文1"])
    }

    @Test @MainActor func triggerRePressDuringTranscribingRestartsRecording() async {
        let recorder = StubRecorder()
        let transcriber = StubTranscriber()
        transcriber.delayNanos = 400_000_000
        let inserter = StubInserter()
        let (machine, start) = makeMachine(recorder: recorder, transcriber: transcriber, inserter: inserter)

        machine.handleTriggerDown()
        await waitUntil { recorder.started }
        recorder.yieldSegment(duration: 1.0)
        try? await Task.sleep(nanoseconds: 100_000_000)
        machine.handleTriggerUp()
        #expect(machine.state == .transcribing(startedAt: start))

        machine.handleTriggerDown()   // re-press: "re-speak"
        #expect(machine.state == .recording(startedAt: start))
        await waitUntil { recorder.startCount == 2 }   // new session's stream is live

        recorder.yieldSegment(duration: 1.0)   // into the NEW stream
        await waitUntil { inserter.insertedTexts.count == 1 }
        #expect(inserter.insertedTexts == ["段文2"])   // stale segment-1 text never leaked in
        machine.handleTriggerUp()
        await machine.waitForPendingWork()
        #expect(machine.state == .idle)
        #expect(machine.outcome == .success)
    }

    // MARK: - Double-press send

    @Test @MainActor func doublePressSendsReturnOnCompletion() async {
        let recorder = StubRecorder()
        let inserter = StubInserter()
        let (machine, _) = makeMachine(recorder: recorder, transcriber: StubTranscriber(), inserter: inserter)
        var clock = Date(timeIntervalSince1970: 1_000)
        machine.now = { clock }

        // Session 1 — a plain single press never sends Return.
        machine.handleTriggerDown()
        await waitUntil { recorder.started }
        recorder.yieldSegment(duration: 1.0)
        await waitUntil { inserter.insertedTexts.count == 1 }
        machine.handleTriggerUp()   // lastReleaseAt = 1000
        await machine.waitForPendingWork()
        #expect(inserter.sendReturnCount == 0)
        #expect(machine.sendEnterOnComplete == false)

        // Session 2 — pressed 0.1s after the previous release → double-press.
        clock = Date(timeIntervalSince1970: 1_000.1)
        machine.handleTriggerDown()
        #expect(machine.sendEnterOnComplete == true)
        await waitUntil { recorder.startCount == 2 }
        recorder.yieldSegment(duration: 1.0)
        await waitUntil { inserter.insertedTexts.count == 2 }
        machine.handleTriggerUp()
        await machine.waitForPendingWork()
        #expect(inserter.sendReturnCount == 1)
        #expect(machine.state == .idle)
        #expect(machine.outcome == .success)
    }

    @Test @MainActor func slowSecondPressIsNotADoublePress() async {
        let recorder = StubRecorder()
        let inserter = StubInserter()
        let (machine, _) = makeMachine(recorder: recorder, transcriber: StubTranscriber(), inserter: inserter)
        var clock = Date(timeIntervalSince1970: 1_000)
        machine.now = { clock }

        machine.handleTriggerDown()
        await waitUntil { recorder.started }
        recorder.yieldSegment(duration: 1.0)
        await waitUntil { inserter.insertedTexts.count == 1 }
        machine.handleTriggerUp()
        await machine.waitForPendingWork()

        clock = Date(timeIntervalSince1970: 1_000.5)   // 0.5s later — outside window
        machine.handleTriggerDown()
        #expect(machine.sendEnterOnComplete == false)
        await waitUntil { recorder.startCount == 2 }
        recorder.yieldSegment(duration: 1.0)
        await waitUntil { inserter.insertedTexts.count == 2 }
        machine.handleTriggerUp()
        await machine.waitForPendingWork()
        #expect(inserter.sendReturnCount == 0)
    }

    @Test @MainActor func userActivityCancelClearsDoublePressFlag() async {
        let recorder = StubRecorder()
        let transcriber = StubTranscriber()
        transcriber.delayNanos = 400_000_000   // keep the session in flight
        let inserter = StubInserter()
        let (machine, _) = makeMachine(recorder: recorder, transcriber: transcriber, inserter: inserter)
        var clock = Date(timeIntervalSince1970: 1_000)
        machine.now = { clock }

        // First press-release, then a second press inside the window.
        machine.handleTriggerDown()
        await waitUntil { recorder.started }
        machine.handleTriggerUp()
        await waitUntil { recorder.stopCount == 1 }

        clock = Date(timeIntervalSince1970: 1_000.1)
        machine.handleTriggerDown()
        #expect(machine.sendEnterOnComplete == true)
        await waitUntil { recorder.startCount == 2 }
        machine.handleTriggerUp()
        #expect(machine.state == .transcribing(startedAt: machine.now()))

        machine.handleUserActivity()   // user clicked mid-flight
        #expect(machine.state == .idle)
        #expect(machine.sendEnterOnComplete == false)
        await machine.waitForPendingWork()
        try? await Task.sleep(nanoseconds: 500_000_000)
        #expect(inserter.sendReturnCount == 0)
    }

    @Test @MainActor func doublePressDuringTranscribingRestartsWithSendFlag() async {
        let recorder = StubRecorder()
        let transcriber = StubTranscriber()
        transcriber.delayNanos = 400_000_000
        let inserter = StubInserter()
        let (machine, _) = makeMachine(recorder: recorder, transcriber: transcriber, inserter: inserter)
        var clock = Date(timeIntervalSince1970: 1_000)
        machine.now = { clock }

        machine.handleTriggerDown()
        await waitUntil { recorder.started }
        recorder.yieldSegment(duration: 1.0)
        try? await Task.sleep(nanoseconds: 100_000_000)
        machine.handleTriggerUp()   // lastReleaseAt = 1000; now transcribing
        #expect(machine.state == .transcribing(startedAt: machine.now()))

        clock = Date(timeIntervalSince1970: 1_000.1)
        machine.handleTriggerDown()   // re-press inside window → re-speak + send
        #expect(machine.state == .recording(startedAt: machine.now()))
        #expect(machine.sendEnterOnComplete == true)

        await waitUntil { recorder.startCount == 2 }
        recorder.yieldSegment(duration: 1.0)
        await waitUntil { inserter.insertedTexts.count == 1 }
        machine.handleTriggerUp()
        await machine.waitForPendingWork()
        #expect(inserter.insertedTexts == ["段文2"])   // stale segment-1 text dropped
        #expect(inserter.sendReturnCount == 1)
    }

    /// Regression: a very fast press-release completes the session while the
    /// start task is still in flight; a second press inside the double-press
    /// window must not fail — the in-flight start is cancelled silently.
    @Test @MainActor func doublePressAfterFastZeroSpeechSessionDoesNotFail() async {
        let recorder = StubRecorder()
        recorder.firstStartDelayNanos = 300_000_000
        let transcriber = StubTranscriber()
        let inserter = StubInserter()
        let (machine, _) = makeMachine(recorder: recorder, transcriber: transcriber, inserter: inserter)

        machine.handleTriggerDown()
        machine.handleTriggerUp()   // release before the first start lands
        machine.handleTriggerDown() // second press inside the window
        machine.handleTriggerUp()
        await machine.waitForPendingWork()
        await waitUntil { recorder.cancelledDuringStart >= 1 }

        #expect(recorder.startCount == 2)
        #expect(recorder.cancelledDuringStart >= 1)
        #expect(machine.outcome == .success)
        #expect(inserter.sendReturnCount == 1)
    }

    /// The mic-stuck race: a re-press during a suspended stop() must not let
    /// the stale stop finish against the NEW session's engine — the epoch /
    /// generation guards are what prevent it.
    @Test @MainActor func rePressDuringSlowStopDoesNotKillNewEngine() async {
        let recorder = StubRecorder()
        recorder.stopDelayNanos = 300_000_000   // wide enough to re-press inside
        let transcriber = StubTranscriber()
        let inserter = StubInserter()
        let (machine, _) = makeMachine(recorder: recorder, transcriber: transcriber, inserter: inserter)

        machine.handleTriggerDown()
        await waitUntil { recorder.started }
        recorder.yieldSegment(duration: 1.0)
        await waitUntil { inserter.insertedTexts.count == 1 }

        machine.handleTriggerUp()   // stop() now suspended in its delay
        await waitUntil { recorder.stopInFlight }

        machine.handleTriggerDown()   // re-press while the old stop is mid-flight
        #expect(machine.state == .recording(startedAt: machine.now()))
        await waitUntil { recorder.startCount == 2 }

        recorder.yieldSegment(duration: 1.0)   // into the NEW stream
        await waitUntil { inserter.insertedTexts.count == 2 }
        #expect(inserter.insertedTexts == ["段文1", "段文2"])

        machine.handleTriggerUp()
        await machine.waitForPendingWork()
        #expect(machine.state == .idle)
        #expect(machine.outcome == .success)
        // Only the real releases stopped the recorder — the stale stop must
        // never have torn down the second session's stream mid-flight.
        #expect(inserter.insertedTexts.count == 2)
    }

    /// Four rapid press-release cycles: only the last session survives, and it
    /// still sends exactly one Return. Stale start tasks must never fail() the
    /// session that won the engine.
    @Test @MainActor func fourRapidPressesKeepOnlyLastSessionAndSendOnce() async {
        let recorder = StubRecorder()
        recorder.stopDelayNanos = 150_000_000
        let transcriber = StubTranscriber()
        transcriber.delayNanos = 100_000_000
        let inserter = StubInserter()
        let (machine, _) = makeMachine(recorder: recorder, transcriber: transcriber, inserter: inserter)
        var clock = Date(timeIntervalSince1970: 1_000)
        machine.now = { clock }

        // Press 1 — no previous release, so never a double-press.
        machine.handleTriggerDown()
        await waitUntil { recorder.startCount == 1 }

        for press in 2...4 {
            machine.handleTriggerUp()
            clock = clock.addingTimeInterval(0.1)   // inside the 0.3s window
            machine.handleTriggerDown()
            #expect(machine.state == .recording(startedAt: machine.now()))
            #expect(machine.sendEnterOnComplete == true)
            await waitUntil { recorder.startCount == press }
        }

        // Let the last session actually produce output.
        recorder.yieldSegment(duration: 1.0)
        await waitUntil { inserter.insertedTexts.count == 1 }
        machine.handleTriggerUp()
        await machine.waitForPendingWork()

        #expect(machine.state == .idle)
        #expect(machine.outcome == .success)
        #expect(inserter.sendReturnCount == 1)
        #expect(machine.sendEnterOnComplete == false)
    }
}
