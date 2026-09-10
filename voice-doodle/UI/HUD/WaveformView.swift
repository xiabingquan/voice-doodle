import SwiftUI

/// 28 rounded bars driven by the recorder's level ring (30 Hz sampling).
/// Per-bar interpolated gradient: deep on the left to bright on the right
/// — see HUDView.waveColor.
struct WaveformView: View {
    var levels: [Float]

    var body: some View {
        let n = max(levels.count, 1)
        HStack(spacing: 3.3) {
            ForEach(Array(levels.enumerated()), id: \.offset) { index, level in
                RoundedRectangle(cornerRadius: 1)
                    .fill(HUDView.waveColor(at: index, of: n))
                    .frame(width: 2, height: max(4, CGFloat(level) * 28))
            }
        }
        .frame(height: 28)
        .animation(.linear(duration: 0.025), value: levels)
    }
}
