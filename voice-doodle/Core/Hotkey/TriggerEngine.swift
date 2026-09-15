import AppKit
import CoreGraphics
import Foundation
import os.log

nonisolated enum TapDecision: Equatable, Sendable {
    case pass
    case swallow
    case passAndDown   // modifier-only triggers: let flagsChanged through
    case passAndUp
    case swallowAndDown // key/mouse triggers: consume the event
    case swallowAndUp

    var isSwallow: Bool {
        switch self {
        case .swallow, .swallowAndDown, .swallowAndUp: return true
        default: return false
        }
    }

    var emitsDown: Bool { self == .passAndDown || self == .swallowAndDown }
    var emitsUp: Bool { self == .passAndUp || self == .swallowAndUp }
}

/// Global CGEventTap for hold-to-talk. The runloop source lives on the main
/// runloop (.commonModes), so callbacks arrive on the main thread and state
/// access uses MainActor.assumeIsolated — no Task hop, preserving down/up order.
@MainActor
final class TriggerEngine {
    private(set) var isTriggerHeld = false
    private var previousFlags: CGEventFlags = []
    private var port: CFMachPort?
    private var source: CFRunLoopSource?
    let config: TriggerConfig

    var onDown: (() -> Void)?
    var onUp: (() -> Void)?
    /// Fires on ESC key-down in any state — the session drops all current
    /// and pending work. Other keys and mouse presses never cancel.
    var onCancel: (() -> Void)?

    init(config: TriggerConfig = .default) {
        self.config = config
    }

    var isRunning: Bool { port != nil }

    /// Returns false when Accessibility is not granted or tap creation fails.
    @discardableResult
    func start() -> Bool {
        guard port == nil else { return true }
        guard AXIsProcessTrusted() else {
            Log.hotkey.error("start failed: accessibility not trusted")
            return false
        }

        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue) |
            (1 << CGEventType.otherMouseDown.rawValue) |
            (1 << CGEventType.otherMouseUp.rawValue)

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: triggerTapCallback,
            userInfo: refcon
        ) else {
            Log.hotkey.error("tapCreate returned nil")
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)

        self.port = port
        self.source = source
        Log.hotkey.info("trigger engine started")
        return true
    }

    func stop() {
        if let port {
            CGEvent.tapEnable(tap: port, enable: false)
        }
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        port = nil
        source = nil
        isTriggerHeld = false
        previousFlags = []
    }

    func emitDown() {
        guard !isTriggerHeld else { return }
        isTriggerHeld = true
        Log.hotkey.info("trigger down")
        onDown?()
    }

    func emitUp() {
        guard isTriggerHeld else { return }
        isTriggerHeld = false
        Log.hotkey.info("trigger up")
        onUp?()
    }

    func handleTapDisabled(_ event: CGEvent) {
        if let port {
            CGEvent.tapEnable(tap: port, enable: true)
        }
        Log.hotkey.warning("tap disabled by system; re-enabled")
        _ = event
    }

    /// Runs on the main runloop (see triggerTapCallback): decides, updates held
    /// state, emits events, and returns the event to pass through or nil to swallow.
    func handleEvent(
        type: CGEventType,
        keyCode: Int64,
        buttonNumber: Int64,
        flags: CGEventFlags,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        let decision = Self.evaluate(
            type: type,
            keyCode: keyCode,
            buttonNumber: buttonNumber,
            flags: flags,
            previousFlags: previousFlags,
            isHeld: isTriggerHeld,
            config: config
        )
        previousFlags = flags
        if decision.emitsDown { emitDown() }
        if decision.emitsUp { emitUp() }
        if type == .keyDown, keyCode == Int64(Constants.Keys.escapeKeyCode) {
            Log.hotkey.info("ESC key-down seen (held=\(self.isTriggerHeld))")
        }
        // ESC stops everything regardless of held state. The trigger can never
        // be ESC (the recorder rejects it), and !emitsDown excludes the
        // trigger's own key-down for any physical-key trigger.
        if Self.isCancelSignal(type: type, keyCode: keyCode), !decision.emitsDown {
            onCancel?()
        }
        return decision.isSwallow ? nil : Unmanaged.passUnretained(event)
    }

    /// Only ESC key-down cancels pending work; every other key and all mouse
    /// presses must pass through untouched.
    nonisolated static func isCancelSignal(type: CGEventType, keyCode: Int64) -> Bool {
        type == .keyDown && keyCode == Int64(Constants.Keys.escapeKeyCode)
    }

    // MARK: - Pure decision function (unit-test battleground)

    nonisolated static func evaluate(
        type: CGEventType,
        keyCode: Int64,
        buttonNumber: Int64,
        flags: CGEventFlags,
        previousFlags: CGEventFlags,
        isHeld: Bool,
        config: TriggerConfig
    ) -> TapDecision {
        switch config.kind {
        case .mouseButton(let button):
            return evaluateMouse(
                type: type,
                buttonNumber: buttonNumber,
                target: button,
                isHeld: isHeld
            )
        case .keyCombo(let keys):
            return evaluateKeys(
                type: type,
                keyCode: keyCode,
                flags: flags,
                previousFlags: previousFlags,
                isHeld: isHeld,
                keys: keys,
                swallowTyping: config.swallowTypingWhileHeld
            )
        }
    }

    private nonisolated static func evaluateMouse(
        type: CGEventType,
        buttonNumber: Int64,
        target: MouseButton,
        isHeld: Bool
    ) -> TapDecision {
        guard buttonNumber == Int64(target.rawValue) else { return .pass }
        switch type {
        case .otherMouseDown:
            return isHeld ? .swallow : .swallowAndDown
        case .otherMouseUp:
            return isHeld ? .swallowAndUp : .swallow
        default:
            return .pass
        }
    }

    private nonisolated static func evaluateKeys(
        type: CGEventType,
        keyCode: Int64,
        flags: CGEventFlags,
        previousFlags: CGEventFlags,
        isHeld: Bool,
        keys: Set<TriggerKey>,
        swallowTyping: Bool
    ) -> TapDecision {
        // A "modifier trigger" is any key whose requirement is a modifier mask
        // (physical keyCode, when present, is only used for flagsChanged matching).
        let modifierTrigger = keys.allSatisfy { $0.modifierMask != 0 }

        if modifierTrigger {
            guard type == .flagsChanged else {
                // Ordinary typing while the modifier trigger is held.
                if isHeld && swallowTyping {
                    return flags.contains(.maskCommand) ? .pass : .swallow
                }
                return .pass
            }

            // Single physical modifier: match by flagsChanged keyCode —
            // device-dependent flag bits are unreliable. Toggle semantics:
            // the same keyCode fires on both press and release.
            if keys.count == 1, let key = keys.first, let wanted = key.keyCode {
                if Int64(wanted) == keyCode {
                    return isHeld ? .passAndUp : .passAndDown
                }
                return .pass
            }

            // Multi-modifier or keyCode-less: match on raw NX_* flag bits.
            let required = keys.reduce(UInt64(0)) { $0 | $1.modifierMask }
            let now = flags.rawValue
            let before = previousFlags.rawValue
            let allNow = (now & required) == required
            let allBefore = (before & required) == required
            if !isHeld && allNow && !allBefore {
                return .passAndDown
            }
            if isHeld && !allNow {
                return .passAndUp
            }
            return .pass
        }

        // Physical-key trigger (single key or combo with modifiers).
        guard let trigger = keys.first(where: { $0.keyCode != nil }),
              let wantedCode = trigger.keyCode else { return .pass }
        let requiredModifiers = keys.reduce(UInt64(0)) { $0 | $1.modifierMask }

        switch type {
        case .keyDown:
            if Int64(wantedCode) == keyCode && (flags.rawValue & requiredModifiers) == requiredModifiers {
                return isHeld ? .swallow : .swallowAndDown
            }
            if isHeld && swallowTyping {
                return flags.contains(.maskCommand) ? .pass : .swallow
            }
            return .pass
        case .keyUp:
            if Int64(wantedCode) == keyCode && isHeld {
                return .swallowAndUp
            }
            if isHeld && swallowTyping {
                return flags.contains(.maskCommand) ? .pass : .swallow
            }
            return .pass
        default:
            return .pass
        }
    }
}

/// C callback: runs on the main runloop (source installed in .commonModes).
private nonisolated let triggerTapCallback: CGEventTapCallBack = { _, type, event, refcon in
    guard let refcon else {
        return Unmanaged.passUnretained(event)
    }
    let engine = Unmanaged<TriggerEngine>.fromOpaque(refcon).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        return MainActor.assumeIsolated {
            engine.handleTapDisabled(event)
            return Unmanaged.passUnretained(event)
        }
    }

    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
    let buttonNumber = event.getIntegerValueField(.mouseEventButtonNumber)
    let flags = event.flags

    return MainActor.assumeIsolated {
        engine.handleEvent(
            type: type,
            keyCode: keyCode,
            buttonNumber: buttonNumber,
            flags: flags,
            event: event
        )
    }
}
