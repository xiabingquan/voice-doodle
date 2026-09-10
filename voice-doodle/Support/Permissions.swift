import AVFoundation
import AppKit
import Foundation

/// Microphone/AX permission status + requests + System Settings openers.
enum Permissions {
    enum MicStatus {
        case authorized, denied, notDetermined
    }

    static func micStatus() -> MicStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .authorized
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }

    /// Requests microphone access if undetermined. Returns whether mic is usable afterwards.
    static func requestMicIfNeeded() async -> Bool {
        switch micStatus() {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        case .denied: return false
        }
    }

    static func isAccessibilityTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    static func openAccessibilitySettings() {
        // TCC pane for Accessibility
        openSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    static func openMicSettings() {
        openSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    /// Shared row actions (wizard + dashboard): request-then-open, identical
    /// on both surfaces. The in-app request also registers the app in the
    /// TCC privacy lists.
    /// One behaviour per click: undetermined → the system dialog only (that
    /// request registers the app and the row turns green on answer); decided
    /// (granted/denied) → Settings pane only, where the toggle lives.
    @MainActor
    static func micRowAction(appState: AppState) {
        Task {
            Log.session.info("mic row action: status=\(String(describing: micStatus()))")
            if micStatus() == .notDetermined {
                _ = await requestMicIfNeeded()
            } else {
                openMicSettings()
            }
            appState.refreshReadiness()
        }
    }

    /// Settings pane only — the row button must never fire the system
    /// prompt (user decision 2026-09-10). Registration for the AX list
    /// comes from prior prompts / AX API use, not from this action.
    @MainActor
    static func axRowAction(appState: AppState) {
        Log.session.info("ax row action: trusted=\(isAccessibilityTrusted())")
        openAccessibilitySettings()
        appState.refreshReadiness()
    }

    private static func openSettings(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}
