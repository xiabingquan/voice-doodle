import Testing
@testable import voice_doodle

struct LevelMeterTests {
    @Test func snapshotPadsWhenShort() {
        let meter = LevelMeter()
        meter.push(0.01)   // -40 dBFS → 0.375 in the -55…-15 window
        let snap = meter.snapshot(count: 4)
        #expect(snap == [0, 0, 0, 0.375])
    }

    @Test func snapshotReturnsDBMappedValues() {
        let meter = LevelMeter()
        meter.push(0)        // silence → 0
        meter.push(0.001)    // ≈ -60 dBFS → 0 (below floor)
        meter.push(0.2)      // ≈ -14 dBFS → ~1
        let snap = meter.snapshot(count: 3)
        #expect(snap[0] == 0)
        #expect(snap[1] < 0.02)
        #expect(snap[2] >= 0.999)
    }

    @Test func ringEvictsBeyondCapacity() {
        let meter = LevelMeter()
        let cycle: [Float] = [0.001, 0.00316, 0.01, 0.0316, 0.2]
        for i in 0..<(LevelMeter.capacity + 10) {
            meter.push(cycle[i % cycle.count])
        }
        let snap = meter.snapshot(count: 10)
        let expected = (LevelMeter.capacity..<(LevelMeter.capacity + 10)).map {
            LevelMeter.displayLevel(rms: cycle[$0 % cycle.count])
        }
        for (got, want) in zip(snap, expected) {
            #expect(abs(got - want) < 0.001)
        }
    }

    @Test func snapshotWindowTakesNewest() {
        let meter = LevelMeter()
        for i in 1...100 { meter.push(0.001 * Float(i)) }
        let snap = meter.snapshot(count: 3)
        let expected = (98...100).map { LevelMeter.displayLevel(rms: 0.001 * Float($0)) }
        for (got, want) in zip(snap, expected) {
            #expect(abs(got - want) < 0.001)
        }
    }

    @Test func displayLevelIsDBMapped() {
        #expect(LevelMeter.displayLevel(rms: 0) == 0)
        #expect(LevelMeter.displayLevel(rms: -1) == 0)
        // -55 dBFS → 0; -40 dBFS ≈ 0.375; -15 dBFS and above → 1
        #expect(LevelMeter.displayLevel(rms: 0.00178) < 0.02)
        #expect(abs(LevelMeter.displayLevel(rms: 0.01) - 0.375) < 0.02)
        #expect(LevelMeter.displayLevel(rms: 0.2) >= 0.999)
        #expect(LevelMeter.displayLevel(rms: 0.5) == 1)
        #expect(LevelMeter.displayLevel(rms: 2) == 1)
    }

    @Test func resetClears() {
        let meter = LevelMeter()
        meter.push(1)
        meter.reset()
        #expect(meter.snapshot(count: 2) == [0, 0])
    }
}
