import Testing
import CoreGraphics
@testable import voice_doodle

struct TriggerEvaluateTests {
    private let rightOption = CGEventFlags(rawValue: Constants.Keys.rightOptionMask)
    private let leftOption = CGEventFlags(rawValue: Constants.Keys.leftOptionMask)
    private let spaceKeyCode: Int64 = 49

    @Test func rightOptionPressEmitsDownAndPasses() {
        let d = TriggerEngine.evaluate(
            type: .flagsChanged, keyCode: 61, buttonNumber: 0,
            flags: rightOption, previousFlags: [], isHeld: false,
            config: .default
        )
        #expect(d == .passAndDown)
    }

    @Test func rightOptionMatchesByKeyCodeEvenWithoutDeviceFlagBits() {
        // Some systems report only the device-independent alternate bit in
        // CGEvent.flags; keyCode 61 must still toggle the trigger.
        let d = TriggerEngine.evaluate(
            type: .flagsChanged, keyCode: 61, buttonNumber: 0,
            flags: .maskAlternate, previousFlags: [], isHeld: false,
            config: .default
        )
        #expect(d == .passAndDown)
    }

    @Test func rightOptionReleaseEmitsUp() {
        let d = TriggerEngine.evaluate(
            type: .flagsChanged, keyCode: 61, buttonNumber: 0,
            flags: [], previousFlags: rightOption, isHeld: true,
            config: .default
        )
        #expect(d == .passAndUp)
    }

    @Test func leftOptionDoesNotTrigger() {
        let d = TriggerEngine.evaluate(
            type: .flagsChanged, keyCode: 58, buttonNumber: 0,
            flags: leftOption, previousFlags: [], isHeld: false,
            config: .default
        )
        #expect(d == .pass)
    }

    @Test func ordinaryTypingSwallowedWhileHeld() {
        let d = TriggerEngine.evaluate(
            type: .keyDown, keyCode: 0 /* A */, buttonNumber: 0,
            flags: [], previousFlags: [], isHeld: true,
            config: .default
        )
        #expect(d == .swallow)
    }

    @Test func commandCombosPassWhileHeld() {
        let d = TriggerEngine.evaluate(
            type: .keyDown, keyCode: 12, buttonNumber: 0,   // ⌘Q
            flags: .maskCommand, previousFlags: [], isHeld: true,
            config: .default
        )
        #expect(d == .pass)
    }

    @Test func swallowTypingCanBeDisabled() {
        var config = TriggerConfig.default
        config.swallowTypingWhileHeld = false
        let d = TriggerEngine.evaluate(
            type: .keyDown, keyCode: 0, buttonNumber: 0,
            flags: [], previousFlags: [], isHeld: true,
            config: config
        )
        #expect(d == .pass)
    }

    @Test func singleKeyHoldTriggersOnItsKeyDown() {
        let config = TriggerConfig(kind: .keyCombo([TriggerKey(keyCode: 49, modifierMask: 0)]))
        let down = TriggerEngine.evaluate(
            type: .keyDown, keyCode: spaceKeyCode, buttonNumber: 0,
            flags: [], previousFlags: [], isHeld: false, config: config
        )
        #expect(down == .swallowAndDown)
        let up = TriggerEngine.evaluate(
            type: .keyUp, keyCode: spaceKeyCode, buttonNumber: 0,
            flags: [], previousFlags: [], isHeld: true, config: config
        )
        #expect(up == .swallowAndUp)
    }

    @Test func otherKeyDownIgnoresSingleKeyTrigger() {
        let config = TriggerConfig(kind: .keyCombo([TriggerKey(keyCode: 49, modifierMask: 0)]))
        let d = TriggerEngine.evaluate(
            type: .keyDown, keyCode: 0, buttonNumber: 0,
            flags: [], previousFlags: [], isHeld: false, config: config
        )
        #expect(d == .pass)
    }

    @Test func mouseSideButtonTriggers() {
        let config = TriggerConfig(kind: .mouseButton(.x1))
        let down = TriggerEngine.evaluate(
            type: .otherMouseDown, keyCode: 0, buttonNumber: 3,
            flags: [], previousFlags: [], isHeld: false, config: config
        )
        #expect(down == .swallowAndDown)
        let up = TriggerEngine.evaluate(
            type: .otherMouseUp, keyCode: 0, buttonNumber: 3,
            flags: [], previousFlags: [], isHeld: true, config: config
        )
        #expect(up == .swallowAndUp)
    }

    @Test func otherMouseButtonIgnoredWhenNotTrigger() {
        let config = TriggerConfig(kind: .mouseButton(.x1))
        let d = TriggerEngine.evaluate(
            type: .otherMouseDown, keyCode: 0, buttonNumber: 2,
            flags: [], previousFlags: [], isHeld: false, config: config
        )
        #expect(d == .pass)
    }

    @Test func userActivityIsPressClassOnly() {
        #expect(TriggerEngine.isUserActivity(type: .keyDown))
        #expect(TriggerEngine.isUserActivity(type: .leftMouseDown))
        #expect(TriggerEngine.isUserActivity(type: .rightMouseDown))
        #expect(TriggerEngine.isUserActivity(type: .otherMouseDown))
        // Releases and modifier toggles are never "another action" — they are
        // part of the trigger's own release cycle.
        #expect(!TriggerEngine.isUserActivity(type: .keyUp))
        #expect(!TriggerEngine.isUserActivity(type: .flagsChanged))
        #expect(!TriggerEngine.isUserActivity(type: .leftMouseUp))
        #expect(!TriggerEngine.isUserActivity(type: .rightMouseUp))
        #expect(!TriggerEngine.isUserActivity(type: .otherMouseUp))
        #expect(!TriggerEngine.isUserActivity(type: .scrollWheel))
        #expect(!TriggerEngine.isUserActivity(type: .mouseMoved))
    }
}
