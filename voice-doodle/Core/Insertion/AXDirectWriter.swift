import AppKit
import ApplicationServices
import Foundation
import os.log

/// AX-based direct text write: replaces the focused element's selected text
/// (empty selection at caret = insert-at-caret), falling back to appending
/// to the element's value with read-back verification.
enum AXDirectWriter {
    enum Outcome: Equatable {
        case insertedViaSelection
        case insertedViaValueAppend
        case failed(String)
    }

    private static func code(_ status: AXError) -> String {
        "\(status.rawValue)"
    }

    private static func isSettable(_ element: AXUIElement, _ attribute: String) -> Bool {
        var settable = DarwinBoolean(false)
        let status = AXUIElementIsAttributeSettable(element, attribute as CFString, &settable)
        Log.insertion.debug("ax isSettable[\(attribute)]: \(self.code(status)) settable=\(settable.boolValue)")
        return status == .success && settable.boolValue
    }

    /// Resolves the focused text element via the system-wide object first
    /// (the common pattern), falling back to per-app and per-window queries.
    static func focusedElement(of app: NSRunningApplication) -> AXUIElement? {
        // Layer 1: system-wide → focused application → focused element
        let systemWide = AXUIElementCreateSystemWide()
        var appRef: CFTypeRef?
        let appStatus = AXUIElementCopyAttributeValue(
            systemWide, kAXFocusedApplicationAttribute as CFString, &appRef
        )
        Log.insertion.debug("ax syswide focused-app: \(self.code(appStatus))")
        if appStatus == .success, let appRef {
            // swiftlint:disable:next force_cast
            let focusedAppElement = appRef as! AXUIElement
            var pidRef: CFTypeRef?
            AXUIElementCopyAttributeValue(focusedAppElement, "AXPID" as CFString, &pidRef)
            let pid = (pidRef as? NSNumber)?.int32Value ?? -1
            Log.insertion.debug("ax syswide focused-app pid=\(pid) target=\(app.processIdentifier)")
            if let direct = copy(focusedAppElement, kAXFocusedUIElementAttribute, label: "syswide focused-element") {
                return direct
            }
        }

        // Layer 2: per-app element by PID
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        if let direct = copy(appElement, kAXFocusedUIElementAttribute, label: "app focused-element") {
            return direct
        }
        if let window = copy(appElement, kAXFocusedWindowAttribute, label: "app focused-window") {
            if let viaWindow = copy(window, kAXFocusedUIElementAttribute, label: "window focused-element") {
                return viaWindow
            }
            return window
        }
        // Enumerate windows as a last-ditch diagnostic.
        var windowsRef: CFTypeRef?
        let windowsStatus = AXUIElementCopyAttributeValue(
            appElement, kAXWindowsAttribute as CFString, &windowsRef
        )
        let count = (windowsRef as? [AnyObject])?.count ?? -1
        Log.insertion.debug("ax app windows: \(self.code(windowsStatus)) count=\(count)")
        return nil
    }

    private static func copy(_ parent: AXUIElement, _ attribute: String, label: String) -> AXUIElement? {
        var ref: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(parent, attribute as CFString, &ref)
        Log.insertion.debug("ax \(label): \(self.code(status))")
        guard status == .success, let ref else { return nil }
        // swiftlint:disable:next force_cast
        return (ref as! AXUIElement)
    }

    static func write(_ text: String, to app: NSRunningApplication) -> Outcome {
        guard let element = focusedElement(of: app) else {
            return .failed("no focused element after all layers")
        }

        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        let role = roleRef as? String ?? "?"
        Log.insertion.debug("ax focused element role=\(role)")

        // Attempt 1: replace the selected text (caret-insert semantics).
        if isSettable(element, kAXSelectedTextAttribute) {
            let status = AXUIElementSetAttributeValue(
                element, kAXSelectedTextAttribute as CFString, text as CFString
            )
            Log.insertion.debug("ax selected-text set: \(self.code(status))")
            if status == .success {
                return .insertedViaSelection
            }
        }

        // Attempt 2: append to the element's value, then verify by reading back.
        guard isSettable(element, kAXValueAttribute) else {
            return .failed("role=\(role) neither selected-text nor value settable")
        }
        var valueRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef)
        let existing = (valueRef as? String) ?? ""
        let appended = existing + text
        let status = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, appended as CFString)
        Log.insertion.debug("ax value set: \(self.code(status))")
        guard status == .success else {
            return .failed("value setAttributeValue \(self.code(status))")
        }
        var verifyRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &verifyRef)
        if let verify = verifyRef as? String, verify.hasSuffix(text) {
            return .insertedViaValueAppend
        }
        return .failed("value write reported success but read-back mismatch")
    }
}
