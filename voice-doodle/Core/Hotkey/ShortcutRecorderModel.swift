import AppKit
import Combine
import Foundation
import os.log

/// Records a new trigger combo via temporary event monitors; the main
/// TriggerEngine tap is stopped by the caller while recording. Modifier
/// detection is keyCode-based — flag bits are unreliable for right ⌥.
@MainActor
final class ShortcutRecorderModel: ObservableObject {
    @Published var isRecording = false
    @Published var conflictWarning: String?

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var modifierOnlyDeadline: Task<Void, Never>?
    /// Physical modifier keys currently held, by flagsChanged keyCode.
    private var heldModifierKeyCodes: Set<UInt16> = []

    /// Called with the captured kind; caller persists and rebuilds the trigger.
    var onCapture: ((TriggerKind) -> Void)?

    func beginRecording() {
        guard !isRecording else { return }
        isRecording = true
        conflictWarning = nil
        heldModifierKeyCodes = []

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .otherMouseDown, .flagsChanged]) { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .otherMouseDown, .flagsChanged]) { [weak self] event in
            if event.keyCode == 53 {   // ESC cancels
                Task { @MainActor in self?.cancel() }
                return nil
            }
            Task { @MainActor in self?.handle(event) }
            // Never swallow flagsChanged — the system needs modifier state.
            return event.type == .flagsChanged ? event : nil
        }
    }

    func cancel() {
        stopMonitors()
        isRecording = false
    }

    func restoreDefault() {
        stopMonitors()
        isRecording = false
        conflictWarning = nil
        onCapture?(.keyCombo([.rightOption]))
    }

    private func handle(_ event: NSEvent) {
        guard isRecording else { return }
        switch event.type {
        case .otherMouseDown:
            if let button = MouseButton(rawValue: UInt32(event.buttonNumber)) {
                finish(.mouseButton(button))
            }
        case .keyDown:
            modifierOnlyDeadline?.cancel()
            // Combo = ONE TriggerKey: the physical key + combined
            // held-modifier masks, taken from held keyCodes — never from
            // event flag bits.
            let trigger = TriggerKey(keyCode: event.keyCode, modifierMask: heldModifierMasks)
            let kind = TriggerKind.keyCombo([trigger])
            conflictWarning = Self.conflictMessage(for: kind)
            finish(kind)
        case .flagsChanged:
            let code = UInt16(event.keyCode)
            guard TriggerKey.modifierCatalog[code] != nil else { return }   // not a modifier
            if heldModifierKeyCodes.contains(code) {
                // Toggle semantics: same keyCode fires on press and release.
                heldModifierKeyCodes.remove(code)
                if heldModifierKeyCodes.isEmpty {
                    // Chord pressed then released with no other key → capture.
                    capture(Set(previouslyHeldKeyCodes))
                }
            } else {
                if heldModifierKeyCodes.isEmpty {
                    previouslyHeldKeyCodes = []   // a fresh chord begins
                }
                previouslyHeldKeyCodes.insert(code)
                heldModifierKeyCodes.insert(code)
                startModifierDeadline()
            }
        default:
            break
        }
    }

    /// Chord members at the moment of release (cleared when a new chord starts).
    private var previouslyHeldKeyCodes: Set<UInt16> = []

    private var heldModifierMasks: UInt64 {
        heldModifierKeyCodes.reduce(UInt64(0)) { $0 | (TriggerKey.modifierCatalog[$1]?.modifierMask ?? 0) }
    }

    private func startModifierDeadline() {
        modifierOnlyDeadline?.cancel()
        modifierOnlyDeadline = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            guard let self, self.isRecording, !self.heldModifierKeyCodes.isEmpty else { return }
            self.capture(Set(self.heldModifierKeyCodes))
        }
    }

    private func capture(_ codes: Set<UInt16>) {
        guard isRecording, !codes.isEmpty else { return }
        let keys = codes.compactMap { TriggerKey.modifierCatalog[$0] }
        guard !keys.isEmpty else { return }
        let kind = TriggerKind.keyCombo(Set(keys))
        conflictWarning = Self.conflictMessage(for: kind)
        finish(kind)
    }

    private func finish(_ kind: TriggerKind) {
        stopMonitors()
        isRecording = false
        onCapture?(kind)
    }

    private func stopMonitors() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        modifierOnlyDeadline?.cancel()
        modifierOnlyDeadline = nil
        heldModifierKeyCodes = []
        previouslyHeldKeyCodes = []
    }

    /// Pure conflict check (unit-testable): known system combos and bare letters.
    nonisolated static func conflictMessage(for kind: TriggerKind) -> String? {
        guard case .keyCombo(let keys) = kind else { return nil }
        // Bare letter/digit keys without modifiers make normal typing impossible.
        if keys.count == 1, let key = keys.first, key.keyCode != nil, key.modifierMask == 0 {
            if let code = key.keyCode, (0...50).contains(code) {
                return "该键按住时无法正常打字，建议搭配修饰键"
            }
        }
        let systemCombos: [UInt16: String] = [
            49: "⌘Space 与 Spotlight 冲突",   // space
            48: "⌘Tab 与系统切换器冲突",       // tab
            50: "⌘` 与窗口切换冲突",           // grave
            12: "⌘Q 与退出冲突",              // Q
            13: "⌘W 与关闭窗口冲突",           // W
        ]
        if keys.count == 1, let key = keys.first, let code = key.keyCode,
           key.modifierMask == Constants.Keys.leftCommandMask, let message = systemCombos[code] {
            return message
        }
        return nil
    }
}
