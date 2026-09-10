import Combine
import Foundation
import os.log

nonisolated enum SessionState: Equatable, Sendable {
    case disabled(reason: DisabledReason)
    case idle
    case recording(startedAt: Date)
    case transcribing(startedAt: Date)
    case inserting
}

nonisolated enum DisabledReason: Equatable, Sendable {
    case micDenied
    case accessibilityDenied
    case apiNotConfigured
    /// Wizard incomplete (cleared only by Finish/Skip; re-opening the
    /// wizard returns to this state).
    case onboardingIncomplete
    case multiple([DisabledReason])
}

nonisolated enum SessionOutcome: Equatable, Sendable {
    case none
    case success
    case failure(VDError)
}

/// Session model (VAD-segment one-shot requests): the segmenter cuts
/// utterances at pauses; each segment is transcribed by one provider request
/// and inserted at the caret. Release flushes and drains the queue.
@MainActor
final class SessionStateMachine: ObservableObject {
    @Published private(set) var state: SessionState = .idle
    /// Per-session result, consumed by the HUD on returning to idle.
    @Published private(set) var outcome: SessionOutcome = .none

    var config: TranscriptionConfig

    /// Injectable clock for deterministic duration tests.
    var now: () -> Date = Date.init

    private let recorder: AudioRecording
    private let transcriber: Transcribing
    private let inserter: TextInserting
    private var sessionTask: Task<Void, Never>?
    private var segmentTask: Task<Void, Never>?
    /// Runs `recorder.cancel()` off `cancelInFlight`'s synchronous path.
    /// Awaited by `waitForPendingWork` so tests can observe teardown finishing.
    private var teardownTask: Task<Void, Never>?
    private var limitTask: Task<Void, Never>?
    /// Most recent failure this session; feeds `outcome` in complete()/fail().
    /// Not published — HUD/menu bar read `outcome` and `state`.
    private var lastFailure: VDError?
    private var insertedAnySegment = false
    /// Per-session VAD stats: cut count, ASR request count and total speech
    /// per press-and-release cycle, summarised in one log line at
    /// complete().
    private var statSegments = 0
    private var statRequests = 0
    private var statRequestOK = 0
    private var statRequestFail = 0
    private var statSpeechSeconds: TimeInterval = 0
    private var pressStartedAt: Date?
    /// Set by `cancelInFlight` only — NOT at release. Release drains whatever
    /// is still in flight (segments, or the tail of a live session), so this
    /// must stay false through `endRecording` or the tail text never lands.
    private var insertionClosed = false
    /// User release timestamp — drives double-press detection.
    private var lastReleaseAt: Date?
    /// Set when the trigger is pressed again within `doublePressWindow` of
    /// the previous release: on normal completion the session sends one
    /// Return keystroke (chat-app "send" gesture).
    private(set) var sendEnterOnComplete = false
    /// Seconds between release and the next press that count as a double-press.
    static let doublePressWindow: TimeInterval = 0.3
    /// Bumped by beginRecording / cancelInFlight / fail. Tasks re-check it:
    /// cancellation is cooperative, so a stale stop task must not tear down
    /// the NEW session's engine.
    private var sessionEpoch = 0

    init(
        recorder: AudioRecording,
        transcriber: Transcribing,
        inserter: TextInserting,
        config: TranscriptionConfig
    ) {
        self.recorder = recorder
        self.transcriber = transcriber
        self.inserter = inserter
        self.config = config
    }

    // MARK: - Readiness

    func applyReadiness(_ ready: Bool, reason: DisabledReason?) {
        switch state {
        case .disabled where ready:
            Log.session.info("readiness restored → idle")
            state = .idle
        case .idle where !ready:
            cancelInFlight()
            Log.session.info("readiness lost → disabled")
            state = .disabled(reason: reason ?? .multiple([]))
        case .disabled:
            // Approved fix (pre-v0.0.1): refresh the reason payload when the
            // readiness cause changes while already disabled — the previous
            // `default: break` left a stale associated value behind.
            let fresh = reason ?? .multiple([])
            if case .disabled(let current) = state, current != fresh {
                Log.session.info("disabled reason refreshed")
                state = .disabled(reason: fresh)
            }
        default:
            break
        }
    }

    // MARK: - Events

    func handleTriggerDown() {
        let isDoublePress = lastReleaseAt
            .map { now().timeIntervalSince($0) < Self.doublePressWindow } ?? false
        switch state {
        case .idle:
            beginRecording()
            sendEnterOnComplete = isDoublePress
        case .transcribing, .inserting:
            // Pressing the trigger again mid-flight means "re-speak" — drop
            // all pending work and start fresh. Within the double-press
            // window it additionally means "send when done".
            Log.session.info("trigger re-pressed → cancel pending & restart (doublePress=\(isDoublePress))")
            cancelInFlight()
            outcome = .none
            beginRecording()
            sendEnterOnComplete = isDoublePress
        default:
            Log.session.debug("trigger down ignored in \(String(describing: self.state))")
        }
    }

    func handleTriggerUp() {
        guard case .recording = state else {
            Log.session.debug("trigger up ignored in \(String(describing: self.state))")
            return
        }
        lastReleaseAt = now()
        endRecording()
    }

    /// Any click or key press after release cancels everything still in
    /// flight. Inserted text stays; synthetic keystrokes from our own
    /// insertion paths are exempt.
    func handleUserActivity() {
        guard !inserter.isSynthesizingInput else { return }
        switch state {
        case .transcribing, .inserting:
            Log.session.info("user activity after release → cancel pending")
            cancelInFlight()
            outcome = .none
            state = .idle
        default:
            break
        }
    }

    /// Auto-stop when the recording cap is reached (timer from beginRecording).
    func handleDurationLimit() {
        guard case .recording = state else { return }
        Log.session.info("duration limit reached")
        limitTask = nil
        endRecording()
    }

    // MARK: - Transitions

    private func beginRecording() {
        lastFailure = nil
        outcome = .none
        insertedAnySegment = false
        statSegments = 0
        statRequests = 0
        statRequestOK = 0
        statRequestFail = 0
        statSpeechSeconds = 0
        pressStartedAt = now()
        insertionClosed = false
        sendEnterOnComplete = false
        sessionEpoch += 1
        let epoch = sessionEpoch
        state = .recording(startedAt: now())
        limitTask = Task { [weak self, config] in
            let cap = max(10, config.maxRecordDuration)
            try? await Task.sleep(nanoseconds: UInt64(cap * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.handleDurationLimit()
        }
        sessionTask = Task { [recorder, weak self] in
            guard let self else { return }
            do {
                let stream = try await recorder.start()
                // start() suspends on the permission call; if a re-press
                // started a newer session meanwhile, this one is stale — tear
                // the engine back down.
                guard epoch == self.sessionEpoch else {
                    await recorder.cancel()
                    return
                }
                self.segmentTask = Task { await self.consumeSegments(stream) }
            } catch is CancellationError {
                // Cancelled/superseded start — never a session failure.
                return
            } catch let error as VDError {
                // A stale start can lose the race for the engine and throw —
                // that must never fail() the session that won.
                guard epoch == self.sessionEpoch else { return }
                Log.session.error("recorder start failed: \(error.shortTitle) | \(Log.describe(error))")
                self.fail(with: error)
            } catch {
                guard epoch == self.sessionEpoch else { return }
                Log.session.error("recorder start failed: \(Log.describe(error))")
                self.fail(with: .audioEngine(Log.describe(error)))
            }
        }
    }

    private func endRecording() {
        limitTask?.cancel()
        limitTask = nil
        // A very fast press-release can complete while the beginRecording
        // start task is still in flight — cancel it here so it never leaks
        // into the next session (silent: CancellationError is not a failure).
        sessionTask?.cancel()
        let epoch = sessionEpoch
        // Release drains a bounded remainder: the in-flight segment plus the
        // flushed final one — both speech the user actually produced.
        state = .transcribing(startedAt: now())
        sessionTask = Task { [recorder, weak self] in
            guard let self else { return }
            // A quick re-press cancels this task AND bumps the epoch; the
            // epoch check (not cancellation) keeps it from stopping the new
            // session's engine.
            guard epoch == self.sessionEpoch, !Task.isCancelled else { return }
            do {
                try await recorder.stop()
            } catch {
                Log.session.error("recorder stop failed: \(Log.describe(error))")
            }
            await self.segmentTask?.value
            self.segmentTask = nil
            // Re-check after the awaits: a re-press during the drain must not
            // let this stale completion clobber the new session's state.
            guard epoch == self.sessionEpoch, !Task.isCancelled else { return }
            await self.complete()
        }
    }

    /// Serial consumer: each VAD segment becomes one ASR request, and the
    /// backend returns that segment's full transcript in one piece. The text
    /// is appended at the caret.
    private func consumeSegments(_ stream: AsyncStream<RecordedAudio>) async {
        for await segment in stream {
            if Task.isCancelled || insertionClosed { return }
            guard segment.duration >= 0.2 else {
                Log.session.info("segment dropped, too short: \(Log.fixed(segment.duration))s")
                continue
            }
            statSegments += 1
            statSpeechSeconds += segment.duration
            Log.session.info("segment #\(self.statSegments) \(Log.fixed(segment.duration))s → transcribing")
            statRequests += 1
            do {
                let text = try await transcriber.transcribe(segment: segment, config: config)
                statRequestOK += 1
                await insertDelta(text)
            } catch {
                statRequestFail += 1
                if Task.isCancelled || insertionClosed {
                    Log.session.info("segment cancelled at release (by design)")
                    return
                }
                if let error = error as? VDError {
                    Log.session.error("segment transcribe failed: \(error.shortTitle)")
                    lastFailure = error
                } else {
                    Log.session.error("segment failed: \(Log.describe(error))")
                    lastFailure = .network(Log.describe(error))
                }
            }
        }
    }

    /// Appends one segment's transcript at the caret. Every backend returns a
    /// complete string per segment, so appending is always correct.
    private func insertDelta(_ delta: String) async {
        // Task.isCancelled covers a stale callback from a cancelled session
        // landing after a re-press already reset insertionClosed for the new one.
        guard !Task.isCancelled, !insertionClosed else { return }
        do {
            try await inserter.insert(delta)
            insertedAnySegment = true
        } catch let error as VDError {
            Log.session.error("delta insert failed: \(error.shortTitle)")
            lastFailure = error
        } catch {
            Log.session.error("delta insert failed: \(Log.describe(error))")
        }
    }

    private func complete() async {
        let hold = pressStartedAt.map { now().timeIntervalSince($0) } ?? 0
        Log.session.info("session stats: vad segments=\(self.statSegments) asr requests=\(self.statRequests) (ok=\(self.statRequestOK) fail=\(self.statRequestFail)) hold=\(Log.fixed(hold))s speech=\(Log.fixed(self.statSpeechSeconds))s")
        Log.session.info("session complete")
        if let lastFailure, !insertedAnySegment {
            outcome = .failure(lastFailure)
        } else {
            outcome = .success
        }
        let shouldSendReturn = sendEnterOnComplete && outcome == .success
        sendEnterOnComplete = false
        state = .idle
        sessionTask = nil
        // Kill any recorder state a raced start may still hold. Awaited here:
        // the recorder actor serializes this cancel before any next session's
        // start, and the caller re-checked the epoch so no session owns the
        // device yet.
        await recorder.cancel()
        if shouldSendReturn {
            Log.session.info("double-press send → Return")
            await inserter.sendReturn()
        }
    }

    private func fail(with error: VDError) {
        lastFailure = error
        outcome = .failure(error)
        sendEnterOnComplete = false
        sessionEpoch += 1
        state = .idle
        sessionTask = nil
        segmentTask = nil
        limitTask?.cancel()
        limitTask = nil
    }

    private func cancelInFlight() {
        insertionClosed = true
        sendEnterOnComplete = false
        // Invalidate any in-flight start/stop body: cancellation alone is
        // cooperative, so an epoch bump is what actually stops a stale stop
        // from tearing down the next session's engine.
        sessionEpoch += 1
        sessionTask?.cancel()
        sessionTask = nil
        segmentTask?.cancel()
        segmentTask = nil
        limitTask?.cancel()
        limitTask = nil
        // Teardown runs off the actor's synchronous path — callers are sync
        // MainActor. The recorder's generation guard keeps a stale teardown
        // off the next session's engine.
        teardownTask = Task { [recorder] in
            await recorder.cancel()
        }
    }

    /// Test seam: awaits the in-flight side-effect tasks.
    func waitForPendingWork() async {
        await sessionTask?.value
        await segmentTask?.value
        await teardownTask?.value
    }
}
