import AppKit

// AppKit entry point — no SwiftUI scene; ⌘, is handled by AppDelegate's
// NSMenu. assumeIsolated satisfies @MainActor isolation on the main thread.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
