import Foundation
import os.log

/// Registrar for the uninstall data-cleanup guard: registers a LaunchAgent
/// that watches the install directory via launchd WatchPaths; a bundle
/// missing for ≥60 s means uninstall — the script purges data, then exits.
enum CleanupAgent {
    static let label = "com.xiabingquan.voice-doodle.cleanup-agent"

    static func register(fileManager: FileManager = .default) {
        let home = fileManager.homeDirectoryForCurrentUser
        let plistURL = home
            .appendingPathComponent("Library/LaunchAgents")
            .appendingPathComponent("\(label).plist")
        guard !fileManager.fileExists(atPath: plistURL.path) else { return }

        guard let bundled = Bundle.main.url(forResource: "cleanup-agent", withExtension: "sh") else {
            Log.misc.error("cleanup-agent.sh missing from app bundle")
            return
        }
        let scriptURL = home.appendingPathComponent(
            "Library/Application Scripts/com.xiabingquan.voice-doodle/cleanup-agent.sh"
        )
        do {
            try fileManager.createDirectory(
                at: scriptURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? fileManager.removeItem(at: scriptURL)
            try fileManager.copyItem(at: bundled, to: scriptURL)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        } catch {
            Log.misc.error("cleanup agent script deploy failed: \(String(describing: error))")
            return
        }

        let appDir = home.appendingPathComponent("Library/Applications").path
        do {
            try plistContents(scriptPath: scriptURL.path, appDir: appDir)
                .write(to: plistURL, atomically: true, encoding: .utf8)
        } catch {
            Log.misc.error("cleanup agent plist write failed: \(String(describing: error))")
            return
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        proc.arguments = ["bootstrap", "gui/\(getuid())", plistURL.path]
        do {
            try proc.run()
            proc.waitUntilExit()
            Log.misc.info("cleanup agent registered (launchctl exit \(proc.terminationStatus))")
        } catch {
            Log.misc.error("cleanup agent bootstrap failed: \(String(describing: error))")
        }
    }

    /// Plist contents (factored out so unit tests can pin the key fields).
    static func plistContents(scriptPath: String, appDir: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(label)</string>
            <key>ProgramArguments</key>
            <array>
                <string>/bin/bash</string>
                <string>\(scriptPath)</string>
            </array>
            <key>WatchPaths</key>
            <array>
                <string>\(appDir)</string>
            </array>
            <key>RunAtLoad</key>
            <false/>
            <key>ProcessType</key>
            <string>Background</string>
        </dict>
        </plist>
        """
    }
}
