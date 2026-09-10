import AppKit
import Combine
import Foundation

/// Publishes live waveform levels and keeps SwiftUI pumping: in the reused,
/// non-activating HUD panel a lone objectWillChange never triggers a body
/// re-evaluation. The timer runs for the panel's entire visible lifetime.
@MainActor
final class WaveformModel: ObservableObject {
    @Published private(set) var levels: [Float] = Array(repeating: 0, count: 28)

    private let recorder: AudioRecorder
    private var timer: Timer?

    init(recorder: AudioRecorder) {
        self.recorder = recorder
    }

    func start() {
        guard timer == nil else { return }
        levels = recorder.levelSnapshot(count: 28)
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tick()
            }
        }
        timer.tolerance = 1.0 / 240.0
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        levels = recorder.levelSnapshot(count: 28)
    }
}
