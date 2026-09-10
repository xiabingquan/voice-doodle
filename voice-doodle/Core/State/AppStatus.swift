import Combine
import Foundation
import os.log

/// Aggregates readiness (permissions + config) into DisabledReason for the
/// state machine. Wizard state is informational only — an open or incomplete
/// wizard never disables the trigger.
@MainActor
final class AppStatus: ObservableObject {
    @Published private(set) var micOK = false
    @Published private(set) var axOK = false
    @Published private(set) var configOK = false
    /// Informational: dashboard banner + first-launch wizard re-show.
    @Published private(set) var wizardCompleted = false

    var isReady: Bool { micOK && axOK && configOK }

    var disabledReason: DisabledReason? {
        var reasons: [DisabledReason] = []
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
