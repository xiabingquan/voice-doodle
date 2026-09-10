import ServiceManagement
import os.log

/// SMAppService login-item wrapper. `reconcile` runs at launch so a moved
/// or upgraded app re-registers against its current bundle path.
enum LoginItem {
    enum Status: Equatable {
        case enabled, disabled, requiresApproval
    }

    static var status: Status {
        switch SMAppService.mainApp.status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        default: .disabled
        }
    }

    /// Align the system registration with the stored preference.
    static func reconcile(preferred: Bool) {
        if preferred, status == .disabled {
            setEnabled(true)
        } else if !preferred, status == .enabled {
            setEnabled(false)
        } else if preferred, status == .requiresApproval {
            Log.misc.info("login item awaiting approval in System Settings")
        }
    }

    static func setEnabled(_ on: Bool) {
        do {
            if on {
                try SMAppService.mainApp.register()
                Log.misc.info("login item registered")
            } else {
                try SMAppService.mainApp.unregister()
                Log.misc.info("login item unregistered")
            }
        } catch {
            Log.misc.error("login item toggle failed: \(String(describing: error))")
        }
    }

    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
