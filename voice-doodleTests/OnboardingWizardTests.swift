import Foundation
import Testing
@testable import voice_doodle

/// Pins wizard/settings field visibility per provider: MiMo/Doubao
/// endpoints are built-in — UI shows only the API key; OpenAI Compatible is
/// the only provider with editable baseURL/model.
struct OnboardingWizardTests {
    @Test func openaiCompatibleShowsAllEditableFields() {
        let spec = OnboardingFieldSpec(provider: .openaiCompatible)
        #expect(spec.showsURLField)
        #expect(spec.showsModelField)
        #expect(spec.urlPrompt == ASRBuiltIns.openaiBaseURL.absoluteString)
        #expect(spec.modelPrompt == ASRBuiltIns.openaiModel)
    }

    @Test func mimoShowsOnlyAPIKey() {
        let spec = OnboardingFieldSpec(provider: .mimo)
        #expect(!spec.showsURLField)
        #expect(!spec.showsModelField)
    }

    @Test func doubaoShowsOnlyAPIKey() {
        let spec = OnboardingFieldSpec(provider: .doubao)
        #expect(!spec.showsURLField)
        #expect(!spec.showsModelField)
    }

    /// Spec prompts must track the built-in constants (single source).
    @Test func specPromptsTrackBuiltIns() {
        #expect(OnboardingFieldSpec(provider: .mimo).urlPrompt == ASRBuiltIns.mimoBaseURL.absoluteString)
        #expect(OnboardingFieldSpec(provider: .mimo).modelPrompt == ASRBuiltIns.mimoModel)
        #expect(OnboardingFieldSpec(provider: .doubao).urlPrompt == ASRBuiltIns.doubaoWsURL.absoluteString)
        #expect(OnboardingFieldSpec(provider: .doubao).modelPrompt == ASRBuiltIns.doubaoResourceID)
    }
}

/// Test-result mapping: UI shows exactly one human line, never raw bodies.
struct TestOutcomeLineTests {
    @Test func successAndSilenceMapToConnected() {
        #expect(TestOutcome.success(detail: "连接成功").uiLine.ok)
        let silence = TestOutcome.failure(.emptyTranscript).uiLine
        #expect(silence.ok)
        #expect(silence.text == "连接成功")
    }

    @Test func authAndNetworkMapToSingleLines() {
        let unauthorized = TestOutcome.failure(.httpStatus(401, body: "{\"secret\":\"diag\"}")).uiLine
        #expect(!unauthorized.ok)
        #expect(unauthorized.text == "认证失败，请检查 API Key")
        let forbidden = TestOutcome.failure(.httpStatus(403, body: nil)).uiLine
        #expect(forbidden.text == "认证失败，请检查 API Key")
        #expect(TestOutcome.failure(.apiNotConfigured).uiLine.text == "请先填写 API Key")
        #expect(TestOutcome.failure(.timeout).uiLine.text == "无法连接服务")
        #expect(TestOutcome.failure(.network("dns")).uiLine.text == "无法连接服务")
        #expect(TestOutcome.failure(.invalidResponse("内部细节")).uiLine.text == "测试失败")
    }

    @Test func uiLineNeverLeaksRawBody() {
        let line = TestOutcome.failure(.httpStatus(500, body: "INTERNAL STACK TRACE")).uiLine
        #expect(!line.text.contains("INTERNAL"))
    }
}

/// Debug-summary presentation: the connectivity test's failure log entry
/// carries raw error values.
struct TestOutcomeDebugSummaryTests {
    @Test func failureRendersStructuredSummary() {
        let outcome = TestOutcome.failure(.httpStatus(401, body: "{\"error\":\"invalid api key\"}"))
        let summary = outcome.debugSummary(provider: .doubao, elapsed: 0.83)!
        #expect(summary.contains("provider: doubao"))
        #expect(summary.contains("error: httpStatus(401)"))
        #expect(summary.contains("body: {\"error\":\"invalid api key\"}"))
        #expect(summary.contains("耗时: 0.83s"))
    }

    @Test func bodyTruncatesToDisplayLimit() {
        let long = String(repeating: "x", count: 300)
        let summary = TestOutcome.failure(.httpStatus(500, body: long))
            .debugSummary(provider: .mimo, elapsed: 1, bodyLimit: 200)!
        #expect(summary.contains(String(repeating: "x", count: 200) + "…"))
        #expect(!summary.contains(String(repeating: "x", count: 201)))
    }

    @Test func nilBodyOmitsBodyLine() {
        let summary = TestOutcome.failure(.httpStatus(403, body: nil))
            .debugSummary(provider: .openaiCompatible, elapsed: 0.5)!
        #expect(summary.contains("error: httpStatus(403)"))
        #expect(!summary.contains("body:"))
    }

    @Test func nonFailureHasNoDebugSummary() {
        #expect(TestOutcome.success(detail: "连接成功").debugSummary(provider: .doubao, elapsed: 1) == nil)
        #expect(TestOutcome.warning(detail: "注意").debugSummary(provider: .doubao, elapsed: 1) == nil)
    }

    @Test func networkErrorCarriesDetailCaseOnly() {
        let summary = TestOutcome.failure(.network("dns lookup failed"))
            .debugSummary(provider: .mimo, elapsed: 2.0)!
        #expect(summary.contains("error: network(dns lookup failed)"))
        #expect(!summary.contains("body:"))
    }
}

/// Readiness gates on permissions + config only; the wizard flag is
/// informational. Mic/AX vary by machine on test hosts, so these tests
/// assert gate membership and flag invariance, never whole-machine isReady.
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
