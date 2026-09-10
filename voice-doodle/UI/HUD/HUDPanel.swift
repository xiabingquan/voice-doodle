import AppKit
import SwiftUI

/// Borderless, non-activating panel hosting the HUD. Never takes key/main.
final class HUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init() {
        let size = HUDView.hudSize
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
    }
}

/// Owns the panel lifecycle. The hosting view is created ONCE and reused —
/// recreating NSHostingView per session cost tens of ms and made the HUD
/// appear noticeably later than the system mic indicator.
@MainActor
final class HUDController {
    private var panel: HUDPanel?
    private var hideTask: Task<Void, Never>?
    private let waveform: WaveformModel

    init(recorder: AudioRecorder) {
        self.waveform = WaveformModel(recorder: recorder)
    }

    func show(session: SessionStateMachine, recorder: AudioRecorder) {
        hideTask?.cancel()
        let panel = ensurePanel(session: session, recorder: recorder)
        panel.layoutIfNeeded()
        position(panel)
        panel.orderFrontRegardless()
        // The heartbeat must keep running while the panel is visible — a
        // lone objectWillChange does not trigger SwiftUI redraws on this
        // reused panel (see WaveformModel comments).
        waveform.start()
    }

    /// Brief error flash, then hide.
    func flashError() {
        hide(after: 2.0)
    }

    func hideImmediately() {
        hideTask?.cancel()
        hideTask = nil
        waveform.stop()
        panel?.orderOut(nil)
    }

    private func hide(after seconds: TimeInterval) {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.waveform.stop()
            self?.panel?.orderOut(nil)
        }
    }

    private func ensurePanel(session: SessionStateMachine, recorder: AudioRecorder) -> HUDPanel {
        if let panel { return panel }
        let panel = HUDPanel()
        let hosting = NSHostingView(rootView: HUDView(session: session, waveform: waveform))
        hosting.frame = NSRect(origin: .zero, size: HUDView.hudSize)
        hosting.autoresizingMask = [.width, .height]
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = .clear
        panel.contentView = hosting
        self.panel = panel
        return panel
    }

    /// Bottom-right corner of the screen under the mouse pointer.
    /// Size is constant (HUDView.hudSize), so the anchor never jumps.
    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let screen else { return }
        let size = HUDView.hudSize
        let x = screen.visibleFrame.maxX - size.width - 24
        let y = screen.frame.minY + 36
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
    }
}
