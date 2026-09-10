import AppKit
import Combine
import Foundation
import SwiftUI
import os.log

/// Root assembly object (root assembly).
@MainActor
final class AppState: ObservableObject {
    let session: SessionStateMachine
    let status: AppStatus
    private(set) var trigger: TriggerEngine
    let recorder: AudioRecorder
    let transcriber: TranscriptionService
    let inserter: TextInserter
    let hud: HUDController
    let configStore: ConfigStore
    let preferences: AppPreferences

    /// Set by AppDelegate at launch; the dashboard footer calls this to
    /// re-open the setup wizard after `onboardingCompleted`.
    var onOpenOnboarding: (() -> Void)?

    private var cancellables = Set<AnyCancellable>()
    private var lastState: SessionState = .idle
    /// Most recent regular (non-menu-bar) app — receives the paste.
    private var lastRegularApp: NSRunningApplication?

    var config: TranscriptionConfig { configStore.config.resolvedTranscription }

    init(
        configStore: ConfigStore? = nil,
        preferences: AppPreferences? = nil
    ) {
        let configStore = configStore ?? ConfigStore()
        let preferences = preferences ?? AppPreferences()
        let recorder = AudioRecorder()
        let transcriber = TranscriptionService()
        let inserter = TextInserter()
        let session = SessionStateMachine(
            recorder: recorder,
            transcriber: transcriber,
            inserter: inserter,
            config: configStore.config.resolvedTranscription
        )
        let status = AppStatus()
        let trigger = TriggerEngine(config: preferences.triggerConfig)

        self.configStore = configStore
        self.preferences = preferences
        self.recorder = recorder
        self.transcriber = transcriber
        self.inserter = inserter
        self.session = session
        self.status = status
        self.trigger = trigger
        self.hud = HUDController(recorder: recorder)

        trigger.onDown = { [weak session] in session?.handleTriggerDown() }
        trigger.onUp = { [weak session] in session?.handleTriggerUp() }
        trigger.onActivity = { [weak session] in session?.handleUserActivity() }

        // The store loads itself after external config.json edits; this hook
        // only re-wires the live session.
        configStore.onExternalChange = { [weak self] in
            self?.applyLoadedConfig()
        }

        status.refresh(
            config: configStore.config.resolvedTranscription,
            wizardCompleted: preferences.onboardingCompleted
        )
        session.applyReadiness(status.isReady, reason: status.disabledReason)
        syncTrigger()
        observeSession()
        observeFrontmostApp()
    }

    // MARK: - Config

    func reloadConfig() {
        configStore.load()
        applyLoadedConfig()
    }

    /// Push the store's already-loaded config into the live session.
    private func applyLoadedConfig() {
        session.config = configStore.config.resolvedTranscription.normalized
        refreshReadiness()
        Log.config.info("config reloaded")
    }

    func updateTranscription(_ mutate: (inout TranscriptionConfig) -> Void) {
        configStore.update { app in
            var resolved = app.resolvedTranscription
            mutate(&resolved)
            app.applyResolvedTranscription(resolved.normalized)
        }
        session.config = configStore.config.resolvedTranscription
        refreshReadiness()
    }

    // MARK: - Shared UI bindings (wizard + dashboard)

    /// Read resolved transcription, write through the config-block path.
    func transcriptionBinding<Value>(_ keyPath: WritableKeyPath<TranscriptionConfig, Value>) -> Binding<Value> {
        Binding(
            get: { self.configStore.config.resolvedTranscription[keyPath: keyPath] },
            set: { newValue in self.updateTranscription { $0[keyPath: keyPath] = newValue } }
        )
    }

    /// Switches the active ASR backend. Only `asr.provider` changes — each
    /// provider block keeps whatever is configured for it, and the "no implicit
    /// fallbacks" rule means the newly active block is used verbatim.
    func setProvider(_ provider: ASRProvider) {
        configStore.update { app in
            app.asr.provider = provider
        }
        session.config = configStore.config.resolvedTranscription.normalized
        refreshReadiness()
        Log.session.info("provider switched to \(provider.rawValue)")
    }

    func updateTrigger(_ kind: TriggerKind) {
        var triggerConfig = preferences.triggerConfig
        triggerConfig.kind = kind
        preferences.triggerConfig = triggerConfig
        rebuildTrigger()
    }

    /// While the shortcut recorder captures a new trigger key, the main event
    /// tap must be down — otherwise it races the capture monitors (a held
    /// modifier starts a recording session, mic goes busy, trigger errors).
    func setTriggerCaptureActive(_ active: Bool) {
        if active {
            trigger.stop()
        } else {
            syncTrigger()
        }
    }

    private func rebuildTrigger() {
        trigger.stop()
        let newTrigger = TriggerEngine(config: preferences.triggerConfig)
        newTrigger.onDown = { [weak session] in session?.handleTriggerDown() }
        newTrigger.onUp = { [weak session] in session?.handleTriggerUp() }
        newTrigger.onActivity = { [weak session] in session?.handleUserActivity() }
        trigger = newTrigger
        syncTrigger()
    }

    /// Session insertion target: frontmost regular app captured at trigger
    /// time; falls back to the notification-tracked app when we ourselves are
    /// frontmost (menu-bar manual path).
    private func sessionTargetApp() -> NSRunningApplication? {
        let front = NSWorkspace.shared.frontmostApplication
        if let front, front.activationPolicy == .regular, front != NSRunningApplication.current {
            Log.insertion.info("session target (frontmost at trigger): \(front.bundleIdentifier ?? "?")")
            return front
        }
        Log.insertion.info("session target (fallback tracked): \(self.lastRegularApp?.bundleIdentifier ?? "none")")
        return lastRegularApp
    }

    // MARK: - Observation

    /// Tracks the last regular app so insertion can re-activate it — the
    /// menu bar makes Voice Doodle frontmost, and ⌘V would go nowhere.
    /// Seeded at launch because activation notifications fire only on switches.
    private func observeFrontmostApp() {
        if let front = NSWorkspace.shared.frontmostApplication,
           front.activationPolicy == .regular,
           front != NSRunningApplication.current {
            lastRegularApp = front
        }
        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didActivateApplicationNotification)
            .compactMap { $0.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication }
            .filter { $0.activationPolicy == .regular && $0 != NSRunningApplication.current }
            .sink { [weak self] app in
                self?.lastRegularApp = app
            }
            .store(in: &cancellables)
    }

    private func observeSession() {
        session.$state
            .removeDuplicates()
            .sink { [weak self] state in
                self?.handleStateChange(state)
            }
            .store(in: &cancellables)
    }

    private func handleStateChange(_ state: SessionState) {
        Log.hud.info("hud state → \(String(describing: state))")
        switch state {
        case .recording:
            // At trigger-down Voice Doodle is not frontmost (global hotkey),
            // so the frontmost app IS the target. Fall back to the tracked
            // app only for the menu-bar path, where we are frontmost.
            configStore.reloadIfFileChanged()
            inserter.targetApp = sessionTargetApp()
            hud.show(session: session, recorder: recorder)
        case .transcribing:
            // Multi-segment sessions: pick up external config.json edits made
            // between segments before the next ASR request.
            configStore.reloadIfFileChanged()
            hud.show(session: session, recorder: recorder)
        case .inserting:
            hud.show(session: session, recorder: recorder)
        case .idle:
            switch lastState {
            case .inserting:
                // No success flash — hide immediately.
                hud.hideImmediately()
            case .transcribing, .recording:
                if case .failure(let error) = session.outcome {
                    // Empty transcript (user said nothing) is not a warning;
                    // hide silently.
                    if error == .emptyTranscript {
                        hud.hideImmediately()
                    } else {
                        hud.flashError()
                    }
                } else {
                    hud.hideImmediately()
                }
            default:
                hud.hideImmediately()
            }
        case .disabled:
            hud.hideImmediately()
        }
        lastState = state
        syncTrigger()
    }

    /// Tap exists only while ready — destroyed when disabled (MAS checklist).
    private func syncTrigger() {
        switch session.state {
        case .disabled:
            if trigger.isRunning { trigger.stop() }
        default:
            if !trigger.isRunning {
                if !trigger.start() {
                    Log.session.error("trigger engine failed to start (accessibility permission?)")
                }
            }
        }
    }

    // MARK: - Lifecycle

    func refreshReadiness() {
        status.refresh(
            config: configStore.config.resolvedTranscription,
            wizardCompleted: preferences.onboardingCompleted
        )
        session.applyReadiness(status.isReady, reason: status.disabledReason)
        syncTrigger()
    }

    func applicationWillTerminate() {
        trigger.stop()
        configStore.stopWatching()
    }
}
