import SwiftUI

/// Transcription-phase spinner: dashed trimmed arc with an angular gradient
/// that reads as a sweeping light as it rotates. Palette/size are
/// parameters — HUD tint at 21pt, gray at smaller size for the dashboard.
struct TranscribeSpinnerView: View {
    var colors: [Color] = [HUDView.tint, HUDView.tintBright, HUDView.tint]
    var size: CGFloat = 21

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.72)
            .stroke(
                AngularGradient(
                    colors: colors,
                    center: .center
                ),
                style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [3.5, 3.5])
            )
            .frame(width: size, height: size)
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: spinning)
            .onAppear { spinning = true }
            .onDisappear { spinning = false }
    }

    @State private var spinning = false
}
