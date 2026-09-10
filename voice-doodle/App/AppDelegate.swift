import AppKit
import os.log
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Test hosts must never reach production state — ConfigStore is pointed
    /// at a scratch directory. See `TestEnvironment`.
    let appState = AppState(
        configStore: TestEnvironment.isTestHost
            ? ConfigStore(directory: TestEnvironment.scratchConfigDirectory())
            : nil
    )
    private let menuBar = MenuBarWindowController()
    private var onboardingWindow: NSWindow?

    /// Build stamp shown in-app, e.g. "v1.0 (abc1234) · Release" — written
    /// into Info.plist by scripts/make_dmg.sh.
    private static var versionLine: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let commit = Bundle.main.object(forInfoDictionaryKey: "VDBuildCommit") as? String
        #if DEBUG
        let config = "Debug"
        #else
        let config = "Release"
        #endif
        return "v\(short) (\(commit ?? "未标记")) · \(config)"
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Launch sequence: no network, no permission prompts.
        // Microphone is requested lazily on first trigger; Accessibility must be
        // granted manually — refreshReadiness picks it up on didBecomeActive.
        Log.session.info("app launched \(Self.versionLine)")
        appState.onOpenOnboarding = { [weak self] in self?.showOnboarding() }
        setupMainMenu()
        menuBar.install(appState: appState)
        // Uninstall data-cleanup guard (test hosts never register — unit
        // tests must not touch the user's LaunchAgents).
        if !TestEnvironment.isTestHost {
            CleanupAgent.register()
            // Re-register on launch so moved/upgraded bundles stay current.
            LoginItem.reconcile(preferred: appState.preferences.launchAtLogin)
            // Close the installer volume window once we run from disk.
            MountedDMG.ejectIfPresent()
        }
        // Test hosts must not auto-open the wizard: AppPreferences hits real
        // UserDefaults.standard even under a test host (same bundle id), and
        // an open wizard would let test interaction flip the user's flag.
        if !TestEnvironment.isTestHost, !appState.preferences.onboardingCompleted {
            showOnboarding()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        appState.refreshReadiness()
    }

    func applicationWillTerminate(_ notification: Notification) {
        appState.applicationWillTerminate()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    /// ⌘, opens the dashboard. The main menu must exist even though menu-bar
    /// apps show no visible menu bar — editing shortcuts (⌘C/⌘V/⌘X/⌘A/⌘Z)
    /// route through the Edit menu to the first responder.
    private func setupMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        let dashboardItem = NSMenuItem(
            title: "设置…",
            action: #selector(openDashboardFromShortcut),
            keyEquivalent: ","
        )
        dashboardItem.target = self
        appMenu.addItem(dashboardItem)
        // ⌘W closes the front window; nil target walks the responder chain
        // to the focused window. Closing the wizard keeps progress.
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(NSMenuItem(
            title: "Close",
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        ))
        // ⌘Q quits immediately; terminate: routes through
        // applicationWillTerminate, so trigger/teardown cleanup runs as with
        // the dashboard Quit button.
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(NSMenuItem(
            title: "退出",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu
        editMenu.addItem(NSMenuItem(title: "Undo", action: NSSelectorFromString("undo:"), keyEquivalent: "z"))
        editMenu.addItem(NSMenuItem(title: "Redo", action: NSSelectorFromString("redo:"), keyEquivalent: "Z"))
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))

        NSApp.mainMenu = mainMenu
    }

    @objc private func openDashboardFromShortcut() {
        menuBar.showDashboard()
    }

    /// Onboarding is AppKit-hosted (no SwiftUI scene at launch). Opening the
    /// wizard resets `onboardingCompleted`; only Finish/Skip sets it true —
    /// exiting mid-flow keeps it false, so the next launch re-shows it.
    private func showOnboarding() {
        appState.preferences.onboardingCompleted = false
        // Flag reset drives first-launch re-show and menu-bar routing only;
        // readiness (permissions + config) no longer gates on it.
        appState.refreshReadiness()
        Log.session.info("onboarding opened; completion flag reset")
        let window: NSWindow
        if let existing = onboardingWindow {
            window = existing
        } else {
            let view = OnboardingView(onClose: { [weak self] skipped in
                self?.onboardingWindow?.close()
                self?.onboardingWindow = nil
                // Skip lands on the dashboard once the wizard window is gone.
                if skipped {
                    DispatchQueue.main.async { [weak self] in
                        self?.menuBar.showDashboard()
                    }
                }
            })
            .environmentObject(appState)
            let hosting = NSHostingController(rootView: view)
            let created = NSWindow(contentViewController: hosting)
            created.title = "设置向导"
            created.styleMask = [.titled, .closable]
            created.isReleasedWhenClosed = false
            NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: created,
                queue: .main
            ) { _ in
                MainActor.assumeIsolated {
                    // Back to menu-bar mode: dock + ⌘Tab presence leave with
                    // the wizard.
                    _ = NSApp.setActivationPolicy(.accessory)
                    Log.session.info("activation policy accessory — wizard closed")
                }
            }
            onboardingWindow = created
            window = created
        }
        // Dead-centre on the current screen: NSWindow.center() only centres
        // horizontally and sits high, so compute the origin explicitly.
        // Step progress is preserved because the window is reused.
        if let screen = window.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            let size = window.frame.size
            window.setFrameOrigin(NSPoint(
                x: visible.midX - size.width / 2,
                y: visible.midY - size.height / 2
            ))
        }
        // Dock icon + ⌘Tab switcher while the wizard is open; willClose
        // restores .accessory. The delayed re-activate pins switcher presence
        // on macOS versions that ignore the policy flip until an activation.
        _ = NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        // Menu-bar apps are non-activating — without explicit activation,
        // makeKeyAndOrderFront will not bring an already-open wizard forward.
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async {
            NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps])
        }
        Log.session.info("activation policy regular — dock + ⌘Tab while wizard open")
        // Opening the wizard closes every other window of this app;
        // centralised here, entry-point agnostic. Async to sidestep
        // window-action callback timing.
        DispatchQueue.main.async { [weak self] in
            self?.closeOtherWindows()
        }
    }

    /// Keeps only the wizard window; closes every other visible
    /// `.normal`-level window. Never iterate NSApp.windows indiscriminately —
    /// the status-bar icon is itself a window; closing it kills the icon.
    private func closeOtherWindows() {
        guard let wizard = onboardingWindow else { return }
        for window in NSApp.windows
        where window !== wizard && window.isVisible && window.level == .normal {
            Log.misc.debug("closing other window: \(String(describing: type(of: window))) '\(window.title)'")
            window.close()
        }
    }
}
