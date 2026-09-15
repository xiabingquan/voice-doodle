import Testing
import AVFoundation
@testable import voice_doodle

/// Per-test limit so a task left running surfaces as a failure in one minute
/// instead of hanging the whole suite — these tests await `waitForPendingWork`
/// directly, which has no built-in bound.
@Suite(.timeLimit(.minutes(1)))
struct StateMachineDoublePressTests {
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
    @Test @MainActor func escCancelClearsDoublePressFlag() async {
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

        machine.handleCancelSignal()   // ESC pressed mid-flight
        #expect(machine.state == .idle)
        #expect(machine.sendEnterOnComplete == false)
        await machine.waitForPendingWork()
        try? await Task.sleep(nanoseconds: 500_000_000)
        #expect(inserter.sendReturnCount == 0)
    }
    /// Empty second leg: the double-press flag is set but the session
    /// inserts nothing (zero-speech hold) — Return must never fire.
    @Test @MainActor func doublePressWithEmptySessionDoesNotSendReturn() async {
        let recorder = StubRecorder()
        let inserter = StubInserter()
        let (machine, _) = makeMachine(recorder: recorder, transcriber: StubTranscriber(), inserter: inserter)

        machine.handleTriggerDown()
        await waitUntil { recorder.started }
        machine.handleTriggerUp()
        await waitUntil { recorder.stopCount >= 1 }

        machine.handleTriggerDown()   // second press inside the window
        #expect(machine.sendEnterOnComplete == true)
        await waitUntil { recorder.startCount == 2 }
        try? await Task.sleep(nanoseconds: 600_000_000)   // hold ≥0.5s, no speech
        machine.handleTriggerUp()
        await machine.waitForPendingWork()

        #expect(machine.outcome == .success)          // signal seen, zero segments
        #expect(inserter.insertedTexts.isEmpty)
        #expect(inserter.sendReturnCount == 0)        // nothing inserted → no Return
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
    }}

