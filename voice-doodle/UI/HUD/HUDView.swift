import os.log
import SwiftUI

/// Icon-only HUD (no text): recording = live waveform, transcription =
/// spinner, errors flash a warning. Success ends immediately. Waveform data
/// comes from WaveformModel.
struct HUDView: View {
    @ObservedObject var session: SessionStateMachine
    @ObservedObject var waveform: WaveformModel

    /// Waveform base colour.
    static let tint = Color(red: 0.17, green: 0.43, blue: 0.80)
    /// Bright end of the gradients: waveform left→right and the spinner's
    /// angular-gradient light stop
    static let tintBright = Color(red: 0.36, green: 0.72, blue: 0.98)
    private static let deepRGB = (0.17, 0.43, 0.80)
    private static let brightRGB = (0.36, 0.72, 0.98)

    /// Per-bar interpolation for the waveform: bar index steps from deep to
    /// bright, reading as a horizontal colour band.
    static func waveColor(at index: Int, of total: Int) -> Color {
        let t = total > 1 ? Double(index) / Double(total - 1) : 0
        return Color(
            red: deepRGB.0 + (brightRGB.0 - deepRGB.0) * t,
            green: deepRGB.1 + (brightRGB.1 - deepRGB.1) * t,
            blue: deepRGB.2 + (brightRGB.2 - deepRGB.2) * t
        )
    }
    /// Fixed size shared by all phases — content-size changes would make
    /// the panel's anchored position jump.
    static let hudSize = CGSize(width: 220, height: 44)

    /// After key release the waveform lingers this long before switching to
    /// the spinner, so a double-press gesture shows the waveform throughout
    /// without a recording→transcribing→recording flicker.
    private static let busyGracePeriod: TimeInterval = 0.3

    @State private var busyGraceExpired = false

    var body: some View {
        content
            .onAppear { evaluateBusyGrace() }
            .onChange(of: rawPhase) { _ in evaluateBusyGrace() }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .hidden:
            EmptyView()
        case .recording:
            capsule {
                WaveformView(levels: waveform.levels)
            }
        case .busy:
            capsule {
                TranscribeSpinnerView()
            }
            .onAppear { Log.hud.info("hud busy view appeared") }
        case .error:
            capsule {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            .onAppear { Log.hud.info("hud error view appeared") }
        }
    }

    private func capsule<Content: View>(@ViewBuilder _ inner: () -> Content) -> some View {
        // No background: icons + waveform only. The fixed frame keeps the
        // bottom-right anchor stable.
        HStack(spacing: 8) { inner() }
            .frame(width: Self.hudSize.width, height: Self.hudSize.height)
            .accessibilityHidden(true)
    }

    private enum Phase {
        case hidden, recording, busy, error
    }

    /// Un-debounced phase straight off the session state.
    private var rawPhase: Phase {
        switch session.state {
        case .recording:
            return .recording
        case .transcribing, .inserting:
            return .busy
        case .idle:
            // No success flash — the spinner simply ends; only errors keep a
            // visible cue.
            if case .failure = session.outcome { return .error }
            return .hidden
        case .disabled:
            return .hidden
        }
    }

    /// The phase actually rendered: a busy phase is held back for
    /// `busyGraceExpired ? busy : .recording`, so a re-press inside the grace
    /// window never shows a spinner at all.
    private var phase: Phase {
        let raw = rawPhase
        if busyGraceExpired { return raw }
        switch raw {
        case .busy:
            return .recording
        default:
            return raw
        }
    }

    /// Arm the grace timer when leaving recording for a busy phase; reset it
    /// (and thus restore instant feedback) for every other phase.
    private func evaluateBusyGrace() {
        switch rawPhase {
        case .busy:
            guard !busyGraceExpired else { return }
            Task { [delay = Self.busyGracePeriod] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled else { return }
                busyGraceExpired = true
            }
        case .recording:
            busyGraceExpired = false
        case .hidden, .error:
            busyGraceExpired = false
        }
    }
}
