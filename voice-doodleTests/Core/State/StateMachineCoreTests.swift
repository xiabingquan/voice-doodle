import Testing
import AVFoundation
@testable import voice_doodle

/// Per-test limit so a task left running surfaces as a failure in one minute
/// instead of hanging the whole suite — these tests await `waitForPendingWork`
/// directly, which has no built-in bound.
@Suite(.timeLimit(.minutes(1)))
struct StateMachineCoreTests {
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
    @Test @MainActor func allZeroCaptureDuringHoldSurfacesMicNoSignal() async {
        let recorder = StubRecorder()
        recorder.sawInputSignal = false
        let inserter = StubInserter()
        let (machine, start) = makeMachine(recorder: recorder, transcriber: StubTranscriber(), inserter: inserter)

        machine.handleTriggerDown()
        await waitUntil { recorder.started }
        // Frozen clock, advanced past the 0.5s zero-signal hold threshold.
        machine.now = { start.addingTimeInterval(1.0) }
        machine.handleTriggerUp()
        await machine.waitForPendingWork()

        #expect(machine.outcome == .failure(.micNoSignal))
        #expect(inserter.insertedTexts.isEmpty)
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
    }}

