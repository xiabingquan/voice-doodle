import Foundation

/// Detects that this process is an XCTest / Swift Testing **test host** and
/// supplies a throwaway config directory — a test-host launch must never
/// read or write the user's real config.json.
enum TestEnvironment {
    /// True when a test bundle is loaded into this process — several
    /// signals, because Swift Testing does not necessarily pull in XCTest.
    static var isTestHost: Bool {
        let env = ProcessInfo.processInfo.environment
        if env["XCTestConfigurationFilePath"] != nil { return true }
        if env["XCTestBundlePath"] != nil { return true }
        if NSClassFromString("XCTestCase") != nil { return true }
        return Bundle.allBundles.contains { $0.bundlePath.hasSuffix(".xctest") }
    }

    /// Throwaway config directory for test-host runs — under the temporary
    /// directory, keyed by pid so parallel hosts do not collide.
    static func scratchConfigDirectory() -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "vd-testhost-config-\(ProcessInfo.processInfo.processIdentifier)",
                isDirectory: true
            )
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// The user's real config directory — exposed only so tests can assert
    /// the scratch path is not this.
    static var productionConfigDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("Voice Doodle", isDirectory: true)
    }
}
