import AppKit
import Combine
import SwiftUI

/// Owns the NSStatusItem and the dashboard window — clicking the status
/// item opens (or fronts) the dashboard. The item length is pinned so the
/// anchor never jumps when busy states swap the button image for a spinner.
@MainActor
final class MenuBarWindowController {
    /// Pinned so the item never resizes between states. `squareLength` is the
    /// system's icon-sized status item; if the `waveform` symbol ever clips,
    /// replace with an explicit point value rather than reverting to variable.
    private static let itemLength = NSStatusItem.squareLength

    private var statusItem: NSStatusItem?
    private var window: NSWindow?
    private var spinner: NSProgressIndicator?
    private var cancellables = Set<AnyCancellable>()
    private weak var appState: AppState?
    /// Re-pins the panel below the status item whenever content sizing
    /// resizes the window — a resize grows the frame from its origin, which
    /// would otherwise detach the top edge from the icon.
    private var windowResizeObserver: NSObjectProtocol?

    func install(appState: AppState) {
        self.appState = appState
        let item = NSStatusBar.system.statusItem(withLength: Self.itemLength)
        item.button?.target = self
        item.button?.action = #selector(statusItemClicked)
        statusItem = item
        // The icon must stay visible in fullscreen spaces: the menu bar
        // auto-hides there, and canJoinAllSpaces + fullScreenAuxiliary keep
        // the status window present when the pointer reveals the bar.
        item.button?.window?.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        appState.session.$state
            .removeDuplicates()
            .sink { [weak self] state in
                self?.updateIcon(for: state)
            }
            .store(in: &cancellables)
        updateIcon(for: appState.session.state)
    }

    // MARK: - Click

    @objc private func statusItemClicked() {
        // Activate this app first: without it, clicking the status item
        // after switching apps leaves windows behind and the click looks
        // unresponsive.
        NSApp.activate(ignoringOtherApps: true)
        // While the wizard is incomplete, the menu-bar entry resumes the
        // wizard — the dashboard is the post-setup detail page and must not
        // bypass setup. Falls back to the dashboard when the hook is nil.
        if let appState, !appState.preferences.onboardingCompleted {
            appState.onOpenOnboarding?()
            return
        }
        if let window, window.isVisible, window.isKeyWindow {
            window.orderOut(nil)
            return
        }
        showDashboard()
    }

    /// Single entry point for showing/hiding the dashboard: shared by status
    /// item clicks and ⌘,. The panel anchors below the status button,
    /// centred on its midpoint, positioned after the window is on screen.
    func showDashboard() {
        if let appState {
            appState.refreshReadiness()
        }
        let window = window ?? makeWindow()
        window.makeKeyAndOrderFront(nil)
        positionBelowStatusItem(window)
        // Layout may finish one runloop after orderFront; re-pin once the
        // final preferred size is in. The resize observer catches later
        // content-driven changes (banners appearing, etc.).
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window, window.isVisible else { return }
            self.positionBelowStatusItem(window)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Anchors the window's top edge 8pt below the status button, centred
    /// on the button horizontally, clamped inside the screen's visible frame.
    private func positionBelowStatusItem(_ window: NSWindow) {
        guard let button = statusItem?.button, let buttonWindow = button.window else { return }
        let buttonFrame = button.convert(button.bounds, to: nil)
        let buttonScreen = buttonWindow.convertToScreen(buttonFrame)
        let size = window.frame.size
        var origin = NSPoint(
            x: buttonScreen.midX - size.width / 2,
            y: buttonScreen.minY - 8 - size.height
        )
        if let visible = (buttonWindow.screen ?? NSScreen.main)?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
            origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
        }
        window.setFrameOrigin(origin)
    }

    private func makeWindow() -> NSWindow {
        guard let appState else { fatalError("MenuBarWindowController.install must run first") }
        let hosting = NSHostingController(
            rootView: MenuBarDashboardView().environmentObject(appState)
        )
        // Content height is ideal-size driven: the Form is width-pinned
        // only, so the window tracks actual content and resizes with
        // footers/banners.
        hosting.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: hosting)
        window.title = "Voice Doodle"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        // No frame autosave: the panel is programmatically anchored and
        // not user-resizable — autosave would reintroduce stale positions.
        windowResizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let window = self.window, window.isVisible else { return }
                self.positionBelowStatusItem(window)
            }
        }
        self.window = window
        return window
    }

    // MARK: - Status item icon
    //
    // This switch is the single source of truth for the icon-state mapping.

    private func updateIcon(for state: SessionState) {
        guard let button = statusItem?.button else { return }
        switch state {
        case .transcribing, .inserting:
            showSpinner(on: button)
        case .disabled:
            hideSpinner()
            setSymbol("exclamationmark.triangle", tint: .systemOrange, on: button)
        case .recording:
            hideSpinner()
            setSymbol("waveform", tint: .systemRed, on: button)
        case .idle:
            hideSpinner()
            setSymbol("waveform", tint: nil, on: button)
        }
    }

    private func setSymbol(_ name: String, tint: NSColor?, on button: NSStatusBarButton) {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Voice Doodle")
        image?.isTemplate = true
        button.image = image
        button.contentTintColor = tint
    }

    /// Spinner is a subview outside status-item layout — pinned to the
    /// button's centre with constraints.
    private func showSpinner(on button: NSStatusBarButton) {
        if spinner == nil {
            let indicator = NSProgressIndicator()
            indicator.style = .spinning
            indicator.controlSize = .small
            indicator.isDisplayedWhenStopped = false
            indicator.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(indicator)
            NSLayoutConstraint.activate([
                indicator.widthAnchor.constraint(equalToConstant: 16),
                indicator.heightAnchor.constraint(equalToConstant: 16),
                indicator.centerXAnchor.constraint(equalTo: button.centerXAnchor),
                indicator.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            ])
            spinner = indicator
        }
        // The item length is pinned, so clearing the image does not collapse it.
        button.image = nil
        spinner?.isHidden = false
        spinner?.startAnimation(nil)
    }

    private func hideSpinner() {
        spinner?.stopAnimation(nil)
        spinner?.isHidden = true
    }
}
