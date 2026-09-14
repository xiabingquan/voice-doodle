import Testing
import AVFoundation
@testable import voice_doodle

/// Per-test limit so a task left running surfaces as a failure in one minute
/// instead of hanging the whole suite — these tests await `waitForPendingWork`
/// directly, which has no built-in bound.
@Suite(.timeLimit(.minutes(1)))
struct StateMachineCancelAndRestartTests {
    /// Double-press restart: the first session's stop() lands after the
    /// second session's start() — the stale stop must be ignored, the new
    /// session's stream must survive, and both segments must insert.
    @Test @MainActor func doublePressRestartIgnoresStaleStop() async {
        let recorder = StubRecorder()
        recorder.holdStopUntilGate = true
        let transcriber = StubTranscriber()
        let inserter = StubInserter()
        let (machine, _) = makeMachine(recorder: recorder, transcriber: transcriber, inserter: inserter)

        machine.handleTriggerDown()
        await waitUntil { recorder.started }
        machine.handleTriggerUp()
        await waitUntil { recorder.stopInFlight }   // session#1 stop parked at the gate
        machine.handleTriggerDown()                 // double-press restart
        await waitUntil { recorder.startCount == 2 }
        recorder.releaseStopGate()                  // stale stop lands AFTER the new start
        await waitUntil { recorder.staleStopCount == 1 }
        recorder.yieldSegment(duration: 1.0)
        recorder.yieldSegment(duration: 1.0)
        recorder.holdStopUntilGate = false
        machine.handleTriggerUp()
        await machine.waitForPendingWork()

        #expect(recorder.staleStopCount == 1)             // stale stop ignored
        #expect(inserter.insertedTexts == ["段文1", "段文2"])
        #expect(inserter.sendReturnCount == 1)           // double-press send flag
        #expect(machine.state == .idle)
    }
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
    }}

