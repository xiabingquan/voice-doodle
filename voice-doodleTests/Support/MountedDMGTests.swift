import Foundation
import Testing
@testable import voice_doodle

struct MountedDMGTests {
    @Test func ejectsOnlyFromInstallLocationWithVolumeMounted() {
        #expect(MountedDMG.shouldEject(
            bundlePath: "/Applications/Voice Doodle.app", volumeExists: true, home: "/Users/u"))
        #expect(MountedDMG.shouldEject(
            bundlePath: "/Users/u/Applications/Voice Doodle.app", volumeExists: true, home: "/Users/u"))
        #expect(!MountedDMG.shouldEject(
            bundlePath: "/Applications/Voice Doodle.app", volumeExists: false, home: "/Users/u"))
        // Running from the DMG itself or a translocated copy must not eject.
        #expect(!MountedDMG.shouldEject(
            bundlePath: "/Volumes/\(MountedDMG.volumeName)/Voice Doodle.app", volumeExists: true, home: "/Users/u"))
        #expect(!MountedDMG.shouldEject(
            bundlePath: "/private/var/folders/xx/AppTranslocation/Voice Doodle.app", volumeExists: true, home: "/Users/u"))
    }

    /// Duplicated by necessity — keep in sync with scripts/make_dmg.sh.
    @Test func volumeNameMatchesPackager() {
        #expect(MountedDMG.volumeName == "Voice Doodle安装向导")
    }
}
