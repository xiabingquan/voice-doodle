import Foundation
import Testing
@testable import voice_doodle

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
            .debugSummary(provider: .mimo7b, elapsed: 1, bodyLimit: 200)!
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
            .debugSummary(provider: .mimo7b, elapsed: 2.0)!
        #expect(summary.contains("error: network(dns lookup failed)"))
        #expect(!summary.contains("body:"))
    }
}
