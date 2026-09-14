import Foundation
import Testing
@testable import voice_doodle

/// AppStatusGatingTests content lives with the state module — wizard flag
/// must never affect readiness; mic/AX vary by machine so only gate
/// membership is asserted.
@MainActor
struct AppStatusGatingTests {
    /// Core invariant: wizard state never changes readiness or reasons.
    @Test func wizardFlagDoesNotAffectReadiness() {
        let config = TranscriptionConfig(apiKey: "sk-x", model: "whisper-1")
        let open = AppStatus()
        open.refresh(config: config, wizardCompleted: false)
        let done = AppStatus()
        done.refresh(config: config, wizardCompleted: true)
        #expect(open.isReady == done.isReady)
        #expect(open.disabledReason == done.disabledReason)
    }

    /// Aggregation contribution test: an empty API key must add
    /// apiNotConfigured regardless of wizard state.
    @Test func missingConfigGatesReadiness() {
        let status = AppStatus()
        status.refresh(config: TranscriptionConfig(), wizardCompleted: false)
        #expect(!status.isReady)
        guard let reason = status.disabledReason else {
            Issue.record("expected a disabled reason")
            return
        }
        let all: [DisabledReason]
        if case .multiple(let list) = reason { all = list } else { all = [reason] }
        #expect(all.contains(.apiNotConfigured))
    }

    /// Consistency: whenever the aggregate reports ready there must be no
    /// disabled reason at all.
    @Test func readyImpliesNoDisabledReason() {
        let status = AppStatus()
        status.refresh(config: TranscriptionConfig(apiKey: "sk-x", model: "whisper-1"), wizardCompleted: true)
        if status.isReady {
            #expect(status.disabledReason == nil)
        }
    }
}
