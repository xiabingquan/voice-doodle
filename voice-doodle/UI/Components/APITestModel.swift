import Combine
import Foundation
import os.log

/// State + actions for the dashboard connectivity test. Every state renders
/// in place inside one fixed-width slot in the provider row so nothing ever
/// shifts; complete outcome detail goes to the log file, not the UI.
@MainActor
final class APITestModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case running
        case succeeded
        case failed
    }

    @Published private(set) var phase: Phase = .idle
    private var revertTask: Task<Void, Never>?

    func run(appState: AppState, snapshot: @escaping () -> TranscriptionConfig) {
        revertTask?.cancel()
        phase = .running
        let config = snapshot()
        Log.test.info("start: provider=\(config.provider.rawValue) baseURL=\(config.baseURL.absoluteString)")
        Task {
            let start = Date()
            let outcome = await appState.transcriber.transcriptionTest(config: config)
            let elapsed = Date().timeIntervalSince(start)
            switch outcome {
            case .success, .warning:
                Log.test.info("provider=\(config.provider.rawValue) elapsed=\(Log.fixed(elapsed))s → success")
                phase = .succeeded
                scheduleRevert()
            case .failure:
                // Complete detail goes to the logs only — the dashboard UI
                // stays free of error bodies.
                let detail = outcome.debugSummary(
                    provider: config.provider,
                    elapsed: elapsed,
                    bodyLimit: 4_000
                ) ?? outcome.uiLine.text
                Log.test.error("provider=\(config.provider.rawValue) elapsed=\(Log.fixed(elapsed))s → FAILED \(detail)")
                phase = .failed
                scheduleRevert()
            }
        }
    }

    /// Both outcomes return to idle after a moment: the slot shows the test
    /// link again — failure persistence lives in the log file, not in the
    /// row.
    private func scheduleRevert() {
        revertTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if Task.isCancelled { return }
            phase = .idle
        }
    }
}
