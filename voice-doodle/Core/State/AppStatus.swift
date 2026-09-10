import Combine
import Foundation
import os.log

/// Aggregates readiness (permissions + config + wizard) into DisabledReason
/// for the state machine. An incomplete wizard counts as not-ready — the
/// trigger stays disabled until Finish or Skip.
@MainActor
final class AppStatus: ObservableObject {
    @Published private(set) var micOK = false
    @Published private(set) var axOK = false
    @Published private(set) var configOK = false
    @Published private(set) var wizardCompleted = false

    var isReady: Bool { micOK && axOK && configOK && wizardCompleted }

    var disabledReason: DisabledReason? {
        var reasons: [DisabledReason] = []
        if !wizardCompleted { reasons.append(.onboardingIncomplete) }
        if !micOK { reasons.append(.micDenied) }
        if !axOK { reasons.append(.accessibilityDenied) }
        if !configOK { reasons.append(.apiNotConfigured) }
        switch reasons.count {
        case 0: return nil
        case 1: return reasons[0]
        default: return .multiple(reasons)
        }
    }

    func refresh(config: TranscriptionConfig, wizardCompleted: Bool) {
        micOK = Permissions.micStatus() == .authorized
        axOK = Permissions.isAccessibilityTrusted()
        configOK = config.isConfigured
        self.wizardCompleted = wizardCompleted
    }
}
