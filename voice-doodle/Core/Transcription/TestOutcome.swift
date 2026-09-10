import Foundation

/// Outcome of the dashboard one-shot connectivity test. `uiLine` (headline)
/// and `debugSummary` (failure detail) are test-button presentation layers;
/// `VDError.shortTitle` serves HUD/logs.
nonisolated enum TestOutcome: Equatable, Sendable {
    case success(detail: String)
    case warning(detail: String)
    case failure(VDError)
}

extension TestOutcome {
    /// One-line UI headline — human-readable, never raw error bodies.
    /// "No speech detected" on the synthesized-silence probe counts as
    /// success — the transport worked.
    var uiLine: (ok: Bool, text: String) {
        switch self {
        case .success(let detail):
            return (true, detail)
        case .warning(let detail):
            return (true, detail)
        case .failure(let error):
            switch error {
            case .emptyTranscript:
                return (true, "连接成功")
            case .apiNotConfigured:
                return (false, "请先填写 API Key")
            case .httpStatus(let code, _) where code == 401 || code == 403:
                return (false, "认证失败，请检查 API Key")
            case .timeout, .network:
                return (false, "无法连接服务")
            default:
                return (false, "测试失败")
            }
        }
    }

    /// Structured debug summary logged on connectivity-test failure — raw
    /// error values (case, body, elapsed) on purpose. `bodyLimit` truncates
    /// the raw body. Nil for non-failure outcomes.
    func debugSummary(provider: ASRProvider, elapsed: TimeInterval, bodyLimit: Int = 200) -> String? {
        guard case .failure(let error) = self else { return nil }
        var lines = [
            "provider: \(provider.rawValue)",
            "error: \(error.debugCaseDescription)"
        ]
        if let body = error.debugBodyValue {
            lines.append("body: \(Self.truncate(body, limit: bodyLimit))")
        }
        lines.append(String(format: "耗时: %.2fs", elapsed))
        return lines.joined(separator: "\n")
    }

    private static func truncate(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "…"
    }
}

extension VDError {
    /// Case name + associated values, no body. Test-button debug block only;
    /// HUD/logs keep `shortTitle`.
    var debugCaseDescription: String {
        switch self {
        case .micDenied: return "micDenied"
        case .micNoSignal: return "micNoSignal"
        case .accessibilityDenied: return "accessibilityDenied"
        case .apiNotConfigured: return "apiNotConfigured"
        case .audioEngine(let detail): return "audioEngine(\(detail))"
        case .encodeFailed: return "encodeFailed"
        case .insertFailed: return "insertFailed"
        case .network(let detail): return "network(\(detail))"
        case .httpStatus(let code, _): return "httpStatus(\(code))"
        case .invalidResponse(let detail): return "invalidResponse(\(detail))"
        case .emptyTranscript: return "emptyTranscript"
        case .timeout: return "timeout"
        }
    }

    /// Raw body carried by the error, when there is one. Debug block only.
    var debugBodyValue: String? {
        switch self {
        case .httpStatus(_, let body): return body
        default: return nil
        }
    }
}
