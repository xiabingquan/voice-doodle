import Foundation
import os.log

/// Ejects the installer DMG volume when the app runs from disk — Finder
/// windows close with their volume; the DMG has no mount-time hooks.
enum MountedDMG {
    /// Must match -volname in scripts/make_dmg.sh.
    static let volumeName = "Voice Doodle安装向导"

    /// Pure decision seam: only an installed app (not a DMG or translocated
    /// copy) may eject, and only while the volume is actually mounted.
    static func shouldEject(bundlePath: String, volumeExists: Bool, home: String = NSHomeDirectory()) -> Bool {
        guard volumeExists else { return false }
        return bundlePath.hasPrefix("/Applications/")
            || bundlePath.hasPrefix(home + "/Applications/")
    }

    static func ejectIfPresent(fileManager: FileManager = .default) {
        let volumePath = "/Volumes/\(volumeName)"
        guard shouldEject(
            bundlePath: Bundle.main.bundlePath,
            volumeExists: fileManager.fileExists(atPath: volumePath)
        ) else { return }
        detach(volumePath: volumePath, force: false)
        guard fileManager.fileExists(atPath: volumePath) else { return }
        detach(volumePath: volumePath, force: true)
    }

    private static func detach(volumePath: String, force: Bool) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        proc.arguments = ["detach", volumePath, "-quiet"] + (force ? ["-force"] : [])
        do {
            try proc.run()
            proc.waitUntilExit()
            Log.misc.info("dmg detach\(force ? " force" : "") exit \(proc.terminationStatus)")
        } catch {
            Log.misc.error("dmg detach failed: \(String(describing: error))")
        }
    }
}
