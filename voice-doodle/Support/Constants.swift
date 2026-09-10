import CoreGraphics
import Foundation

enum Constants {
    enum Defaults {
        static let triggerConfig = "config.trigger"
        static let onboardingCompleted = "flags.onboardingCompleted"
        static let launchAtLogin = "flags.launchAtLogin"
    }

    enum Timing {
        static let minRecording: TimeInterval = 0.3
        static let defaultMaxRecording: TimeInterval = 300
        static let pasteSettle: UInt64 = 120_000_000
    }

    enum Keys {
        static let rightOptionKeyCode: UInt16 = 61   // kVK_Option_Right
        static let leftOptionKeyCode: UInt16 = 58    // kVK_Option
        static let leftCommandKeyCode: UInt16 = 55   // kVK_Command
        static let rightCommandKeyCode: UInt16 = 54  // kVK_Command right
        static let leftShiftKeyCode: UInt16 = 56     // kVK_Shift
        static let rightShiftKeyCode: UInt16 = 60    // kVK_Shift right
        static let leftControlKeyCode: UInt16 = 59   // kVK_Control
        static let rightControlKeyCode: UInt16 = 62  // kVK_Control right
        static let rightOptionMask: UInt64 = 0x0020_0000   // NX_DEVICERALTKEYMASK
        static let leftOptionMask: UInt64 = 0x0000_0020    // NX_DEVICELALTKEYMASK
        static let leftCommandMask: UInt64 = 0x0000_0008   // NX_DEVICELCMDKEYMASK
        static let rightCommandMask: UInt64 = 0x0000_0010  // NX_DEVICERCMDKEYMASK
        static let leftShiftMask: UInt64 = 0x0000_0002     // NX_DEVICELSHIFTKEYMASK
        static let rightShiftMask: UInt64 = 0x0000_0004    // NX_DEVICERSHIFTKEYMASK
        static let leftControlMask: UInt64 = 0x0000_0001   // NX_DEVICELCTLKEYMASK
        static let rightControlMask: UInt64 = 0x0000_2000  // NX_DEVICERCTLKEYMASK
        /// All device-dependent modifier bits (side-accurate; present in both
        /// CGEvent.flags and NSEvent.modifierFlags raw values).
        static let deviceModifierMasks: UInt64 =
            leftCommandMask | rightCommandMask
            | leftShiftMask | rightShiftMask
            | leftOptionMask | rightOptionMask
            | leftControlMask | rightControlMask
        static let ansiVKeyCode: CGKeyCode = 0x09    // kVK_ANSI_V
        static let backspaceKeyCode: CGKeyCode = 0x33   // kVK_Delete
        static let leftArrowKeyCode: CGKeyCode = 0x7B   // kVK_LeftArrow
        static let returnKeyCode: CGKeyCode = 0x24      // kVK_Return
        static let commandKeyCode: CGKeyCode = 0x37     // kVK_Command
        static let shiftKeyCode: CGKeyCode = 0x38       // kVK_Shift
        static let optionKeyCode: CGKeyCode = 0x3A      // kVK_Option
        static let controlKeyCode: CGKeyCode = 0x3B     // kVK_Control
    }
}
