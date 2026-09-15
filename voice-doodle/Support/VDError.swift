import Foundation
import os.log

nonisolated enum VDError: Error, Equatable {
    case micDenied
    /// Capture ran but every buffer was zero — revoked mic feeds silence.
    case micNoSignal
    case accessibilityDenied
    case apiNotConfigured
    case audioEngine(String)
    case encodeFailed
    case insertFailed
    /// Dictation-time window closed or its app quit — transcript discarded
    /// silently; never surfaces on the HUD by design.
    case insertionTargetGone
    case network(String)
    case httpStatus(Int, body: String?)
    case invalidResponse(String)
    case emptyTranscript
    case timeout

    /// Single copy table for HUD/log surfaces (≤12 chars). The test-button
    /// presentation layers live separately on TestOutcome.uiLine /
    /// TestOutcome.debugSummary.
    var shortTitle: String {
        switch self {
        case .micDenied: return "麦克风未授权"
        case .micNoSignal: return "麦克风无信号"
        case .accessibilityDenied: return "辅助功能未授权"
        case .apiNotConfigured: return "API 未配置"
        case .audioEngine: return "录音失败"
        case .encodeFailed: return "编码失败"
        case .insertFailed: return "输入失败"
        case .insertionTargetGone: return "目标窗口已关闭"
        case .network: return "网络错误"
        case .httpStatus(let code, _):
            switch code {
            case 401, 403: return "密钥无效"
            case 404: return "地址错误"
            case 429: return "请求过于频繁"
            default: return "服务端错误"
            }
        case .invalidResponse: return "响应异常"
        case .emptyTranscript: return "未识别到语音"
        case .timeout: return "转录超时"
        }
    }
}
