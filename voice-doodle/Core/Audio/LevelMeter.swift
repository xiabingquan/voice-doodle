import Foundation

/// Ring buffer of recent RMS values for the HUD waveform. Not actor-isolated:
/// pushed from the audio tap's serial queue, snapshotted from any thread.
/// Internal lock makes cross-thread use safe.
nonisolated final class LevelMeter: @unchecked Sendable {
    static let capacity = 512

    private let lock = NSLock()
    private var ring: [Float] = []
    private var nextIndex = 0

    func push(_ rms: Float) {
        lock.lock()
        defer { lock.unlock() }
        if ring.count < Self.capacity {
            ring.append(rms)
        } else {
            ring[nextIndex] = rms
            nextIndex = (nextIndex + 1) % Self.capacity
        }
    }

    /// Most recent `count` values, oldest first, mapped through `displayLevel`
    /// so bar heights are dB-encoded 0...1 fractions. Padded with 0 when shorter.
    func snapshot(count: Int) -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        guard count > 0 else { return [] }
        let ordered: [Float]
        if ring.count < Self.capacity {
            ordered = ring
        } else {
            ordered = Array(ring[nextIndex...] + ring[..<nextIndex])
        }
        let padded: [Float]
        if ordered.count >= count {
            padded = Array(ordered.suffix(count))
        } else {
            padded = Array(repeating: 0, count: count - ordered.count) + ordered
        }
        return padded.map { $0 > 0 ? Self.displayLevel(rms: $0) : 0 }
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        ring.removeAll()
        nextIndex = 0
    }

    /// Display mapping: bar height encodes loudness in dB.
    /// RMS → dBFS (20·log10), linearly normalized into a -55…-15 dBFS window.
    static func displayLevel(rms: Float) -> Float {
        guard rms > 0 else { return 0 }
        let db = 20 * log10(rms)
        let floor: Float = -55
        let ceiling: Float = -15
        let clamped = min(ceiling, max(floor, db))
        return (clamped - floor) / (ceiling - floor)
    }
}
