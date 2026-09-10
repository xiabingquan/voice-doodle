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

    /// Triggers the system's "would like to control this computer" prompt,
    /// which also registers the app in the Accessibility list. The user still
    /// has to tick the checkbox (or be taken to System Settings to do so).
    @discardableResult
    static func requestAccessibilityPrompt() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
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
    @MainActor
    static func micRowAction(appState: AppState) {
        Task {
            _ = await requestMicIfNeeded()
            appState.refreshReadiness()
        }
        openMicSettings()
    }

    @MainActor
    static func axRowAction(appState: AppState) {
        requestAccessibilityPrompt()
        openAccessibilitySettings()
        appState.refreshReadiness()
    }

    private static func openSettings(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}
