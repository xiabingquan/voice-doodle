import Foundation
import os.log

/// A trigger key: either a pure modifier (mask + physical keyCode when known)
/// or a physical key (+ optional modifier requirements).
nonisolated struct TriggerKey: Hashable, Codable, Sendable {
    /// Physical key code; nil when unknown (flags-bit matching is used instead).
    var keyCode: UInt16?
    /// Required raw NX_* modifier bits; 0 when none.
    var modifierMask: UInt64

    /// Right ⌥: match primarily by flagsChanged keyCode 61 — device flag bits
    /// are not always present in CGEvent.flags, keyCode is reliable.
    static let rightOption = TriggerKey(keyCode: Constants.Keys.rightOptionKeyCode, modifierMask: Constants.Keys.rightOptionMask)

    /// keyCode → TriggerKey: side-accurate mask derived from the physical
    /// key, never from event flag bits. Single source for capture and
    /// display; CGEvent masks stay in Constants.Keys.
    static let modifierCatalog: [UInt16: TriggerKey] = [
        Constants.Keys.rightCommandKeyCode: TriggerKey(keyCode: Constants.Keys.rightCommandKeyCode, modifierMask: Constants.Keys.rightCommandMask),
        Constants.Keys.leftCommandKeyCode: TriggerKey(keyCode: Constants.Keys.leftCommandKeyCode, modifierMask: Constants.Keys.leftCommandMask),
        Constants.Keys.leftShiftKeyCode: TriggerKey(keyCode: Constants.Keys.leftShiftKeyCode, modifierMask: Constants.Keys.leftShiftMask),
        Constants.Keys.leftOptionKeyCode: TriggerKey(keyCode: Constants.Keys.leftOptionKeyCode, modifierMask: Constants.Keys.leftOptionMask),
        Constants.Keys.leftControlKeyCode: TriggerKey(keyCode: Constants.Keys.leftControlKeyCode, modifierMask: Constants.Keys.leftControlMask),
        Constants.Keys.rightShiftKeyCode: TriggerKey(keyCode: Constants.Keys.rightShiftKeyCode, modifierMask: Constants.Keys.rightShiftMask),
        Constants.Keys.rightOptionKeyCode: TriggerKey(keyCode: Constants.Keys.rightOptionKeyCode, modifierMask: Constants.Keys.rightOptionMask),
        Constants.Keys.rightControlKeyCode: TriggerKey(keyCode: Constants.Keys.rightControlKeyCode, modifierMask: Constants.Keys.rightControlMask),
    ]

    /// Modifier keyCodes → side-qualified display symbols (never a bare
    /// "key 54").
    static let modifierDisplayNames: [UInt16: String] = [
        Constants.Keys.rightCommandKeyCode: "右⌘",
        Constants.Keys.leftCommandKeyCode: "⌘",
        Constants.Keys.leftShiftKeyCode: "⇧",
        Constants.Keys.leftOptionKeyCode: "⌥",
        Constants.Keys.leftControlKeyCode: "⌃",
        Constants.Keys.rightShiftKeyCode: "右⇧",
        Constants.Keys.rightOptionKeyCode: "右⌥",
        Constants.Keys.rightControlKeyCode: "右⌃",
    ]
}

nonisolated enum MouseButton: UInt32, Codable, Sendable {
    case middle = 2   // kCGMouseButtonCenter
    case x1 = 3       // side button "back"
    case x2 = 4       // side button "forward"
}

nonisolated enum TriggerKind: Hashable, Codable, Sendable {
    case keyCombo(Set<TriggerKey>)
    case mouseButton(MouseButton)
}

nonisolated struct TriggerConfig: Codable, Equatable, Sendable {
    var kind: TriggerKind
    var swallowTypingWhileHeld: Bool

    init(kind: TriggerKind = .keyCombo([.rightOption]), swallowTypingWhileHeld: Bool = true) {
        self.kind = kind
        self.swallowTypingWhileHeld = swallowTypingWhileHeld
    }

    static let `default` = TriggerConfig()
}

/// Human-readable description for a trigger kind (dashboard recorder row,
/// wizard surfaces). Display names come from TriggerKey.modifierDisplayNames.
enum TriggerDescriptor {
    static func describe(_ kind: TriggerKind) -> String {
        switch kind {
        case .mouseButton(let button):
            switch button {
            case .middle: return "按住 鼠标中键"
            case .x1: return "按住 鼠标侧键「后退」"
            case .x2: return "按住 鼠标侧键「前进」"
            }
        case .keyCombo(let keys):
            if keys == [.rightOption] { return "按住 右⌥" }
            let parts = keys.sorted { ($0.keyCode ?? 255) < ($1.keyCode ?? 255) }.map(describeKey)
            return "按住 " + parts.joined(separator: "+")
        }
    }

    private static func describeKey(_ key: TriggerKey) -> String {
        if let code = key.keyCode, let name = TriggerKey.modifierDisplayNames[code] { return name }
        var s = ""
        let m = key.modifierMask
        let k = Constants.Keys.self
        if m & k.rightCommandMask != 0 { s += "右⌘" } else if m & k.leftCommandMask != 0 { s += "⌘" }
        if m & k.rightShiftMask != 0 { s += "右⇧" } else if m & k.leftShiftMask != 0 { s += "⇧" }
        if m & k.rightOptionMask != 0 { s += "右⌥" } else if m & k.leftOptionMask != 0 { s += "⌥" }
        if m & k.rightControlMask != 0 { s += "右⌃" } else if m & k.leftControlMask != 0 { s += "⌃" }
        if let code = key.keyCode { s += "键\(code)" }
        return s
    }
}
