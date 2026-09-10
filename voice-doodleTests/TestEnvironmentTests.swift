import Foundation
import Testing
@testable import voice_doodle

/// Tests must not read or write the user's real config.json — without the
/// test-host redirect, ConfigStore would open the production directory.
@MainActor
struct TestEnvironmentTests {
    /// The load-bearing assertion. If this fails, `AppDelegate` falls back to
    /// the real `ConfigStore` and every test run is a threat to the user's
    /// config — fix detection, do not relax this.
    @Test func testHostProcessIsDetected() {
        #expect(TestEnvironment.isTestHost)
    }

    @Test func scratchConfigDirectoryIsNotTheProductionOne() throws {
        let scratch = TestEnvironment.scratchConfigDirectory()
        let production = TestEnvironment.productionConfigDirectory
        #expect(scratch.path != production.path)
        #expect(scratch.path.hasPrefix(FileManager.default.temporaryDirectory.path))
        #expect(FileManager.default.fileExists(atPath: scratch.path))
        // Production lives under Application Support; scratch must not.
        #expect(!scratch.path.contains("Application Support"))
    }

    /// A store pointed at the scratch directory must never observe the
    /// user's values — seeing production data here means isolation is broken.
    @Test func scratchStoreSeesDefaultsNotTheUsersConfig() throws {
        let store = ConfigStore(directory: TestEnvironment.scratchConfigDirectory())
        #expect(store.config.version == 3)
        #expect(store.config.asr.provider == .mimo)
        #expect(store.config.asr.doubao.apiKey.isEmpty)
        #expect(store.config.asr.mimo.apiKey.isEmpty)
        #expect(store.loadError == nil)
        // Whatever it wrote landed inside the scratch directory.
        #expect(FileManager.default.fileExists(atPath: store.fileURL.path))
        #expect(store.fileURL.path.hasPrefix(FileManager.default.temporaryDirectory.path))
    }
}
