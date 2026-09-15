import AppKit
import Foundation
import os.log

protocol TextInserting: AnyObject {
    func insert(_ text: String) async throws
    /// True while this inserter is posting synthetic keystrokes (⌘V / Return).
    /// Those events re-enter the global event tap — the session must not
    /// mistake them for user activity and cancel itself.
    var isSynthesizingInput: Bool { get }
    /// Posts a single Return keystroke to the frontmost app (double-press send).
    func sendReturn() async
}

extension TextInserting {
    var isSynthesizingInput: Bool { false }
    func sendReturn() async {}
}

/// Insertion order: AX direct write first, clipboard + ⌘V as fallback — AX
/// write attributes are app-dependent (Terminal exposes none, Electron often
/// cannot resolve the text element) and ⌘V reaches every app.
@MainActor
final class TextInserter: TextInserting {
    private let guard_ = PasteboardGuard()
    private var syntheticDepth = 0
    private var lastSyntheticEventAt: Date?

    /// Posted events reach the global tap slightly after `post` returns —
    /// the short trailing window keeps the flag honest across that gap.
    var isSynthesizingInput: Bool {
        if syntheticDepth > 0 { return true }
        guard let last = lastSyntheticEventAt else { return false }
        return Date().timeIntervalSince(last) < 0.25
    }

    /// App that should receive the paste; re-activated before posting ⌘V.
    /// Strong reference on purpose — NSRunningApplication instances are
    /// ephemeral and a weak ref died between trigger and insertion.
    var targetApp: NSRunningApplication?
    /// Dictation-time window inside targetApp — raised before insertion so
    /// text lands in that window, not whichever one is focused now.
    var targetWindow: AXUIElement?

    func insert(_ text: String) async throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw VDError.emptyTranscript }
        try Task.checkCancellation()

        guard Permissions.isAccessibilityTrusted() else {
            Log.insertion.error("accessibility not trusted")
            throw VDError.accessibilityDenied
        }

        // Anchor gone → silent discard by design; never leak into another window.
        guard anchorAvailable() else {
            Log.insertion.info("anchor gone; discarding transcript silently")
            throw VDError.insertionTargetGone
        }

        activateTargetAppIfNeeded()
        raiseAnchorWindow()
        // Wait until the target actually reports active (backgrounded apps are
        // slow), then give it a beat to assign focus to its text field.
        if let target = targetApp, !target.isTerminated, target != NSRunningApplication.current {
            for _ in 0..<10 where !target.isActive {
                try await Task.sleep(nanoseconds: 50_000_000)   // cancellable
            }
            Log.insertion.debug("target active=\(target.isActive)")
            try await Task.sleep(nanoseconds: 150_000_000)
            try Task.checkCancellation()

            // Path 1: AX direct write — closed loop, no clipboard, no synthetic keys.
            let outcome = AXDirectWriter.write(trimmed, to: target)
            switch outcome {
            case .insertedViaSelection, .insertedViaValueAppend:
                Log.insertion.info("ax direct write ok (\(String(describing: outcome)))")
                return
            case .failed(let reason):
                Log.insertion.warning("ax direct write failed (\(reason)); falling back to paste")
            }
        }

        // Path 2: clipboard + synthesized ⌘V fallback.
        try await pasteFallback(trimmed)
    }

    private func pasteFallback(_ trimmed: String) async throws {
        syntheticDepth += 1
        defer { syntheticDepth -= 1 }
        let backup = guard_.backup()
        let writtenChangeCount = guard_.writePlainText(trimmed)
        let wroteOK = NSPasteboard.general.string(forType: .string) == trimmed
        Log.insertion.info("pasteboard write \(wroteOK ? "ok" : "FAILED"), \(trimmed.count) chars")

        do {
            try await Task.sleep(nanoseconds: 150_000_000)   // cancellable
            try Task.checkCancellation()

            guard postPaste() else {
                throw VDError.insertFailed
            }

            try await Task.sleep(nanoseconds: 500_000_000)   // cancellable

            // Restore only if the previous clipboard held something worth keeping —
            // never blank out what we just pasted.
            let hadPreviousContent = backup.contents[.string] != nil || !backup.contents.isEmpty
            if hadPreviousContent, guard_.currentChangeCount() == writtenChangeCount {
                guard_.restore(backup)
                Log.insertion.info("pasteboard restored")
            }
            Log.insertion.info("inserted \(trimmed.count) chars via paste fallback")
        } catch {
            // Cancelled before the ⌘V went out: undo the clipboard write so a
            // late paste elsewhere can never resurrect it. Never post ⌘V
            // after cancellation — that pastes stale clipboard content.
            if guard_.currentChangeCount() == writtenChangeCount {
                guard_.restore(backup)
                Log.insertion.info("cancelled before paste; clipboard restored")
            }
            throw error
        }
    }

    /// Liveness of the trigger-time anchor: the app must still run, and a
    /// captured window must still answer AX queries. No window captured at
    /// trigger time = app-level anchor, still valid.
    private func anchorAvailable() -> Bool {
        guard let target = targetApp, !target.isTerminated else { return false }
        guard let window = targetWindow else { return true }
        var role: CFTypeRef?
        return AXUIElementCopyAttributeValue(window, kAXRoleAttribute as CFString, &role) == .success
    }

    /// Brings the dictation-time window forward within its app (deminiaturize,
    /// raise, main). Focus stays on it after insertion — no restore.
    private func raiseAnchorWindow() {
        guard let window = targetWindow else { return }
        var minimized: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimized) == .success,
           (minimized as? Bool) == true {
            AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        Log.insertion.debug("anchor window raised")
    }

    private func activateTargetAppIfNeeded() {
        let current = NSRunningApplication.current
        if let target = targetApp, !target.isTerminated, target != current {
            Log.insertion.info("activating target app \(target.bundleIdentifier ?? "unknown")")
            target.activate()
        } else {
            let front = NSWorkspace.shared.frontmostApplication
            Log.insertion.warning("no target app; frontmost=\(front?.bundleIdentifier ?? "none")")
        }
    }

    private func postPaste() -> Bool {
        let source = CGEventSource(stateID: .hidSystemState)
        guard
            let down = CGEvent(keyboardEventSource: source, virtualKey: Constants.Keys.ansiVKeyCode, keyDown: true),
            let up = CGEvent(keyboardEventSource: source, virtualKey: Constants.Keys.ansiVKeyCode, keyDown: false)
        else {
            return false
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        lastSyntheticEventAt = Date()
        return true
    }

    /// Double-press send: one Return keystroke to the frontmost app.
    func sendReturn() async {
        guard Permissions.isAccessibilityTrusted() else {
            Log.insertion.error("sendReturn skipped: accessibility not trusted")
            return
        }
        let source = CGEventSource(stateID: .hidSystemState)
        guard
            let down = CGEvent(keyboardEventSource: source, virtualKey: Constants.Keys.returnKeyCode, keyDown: true),
            let up = CGEvent(keyboardEventSource: source, virtualKey: Constants.Keys.returnKeyCode, keyDown: false)
        else {
            return
        }
        down.flags = []
        up.flags = []
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        lastSyntheticEventAt = Date()
        Log.insertion.info("sent Return (double-press)")
    }
}
