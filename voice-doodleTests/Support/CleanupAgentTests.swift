import Foundation
import Testing
@testable import voice_doodle

struct CleanupAgentTests {
    @Test func plistWiresWatchPathsAndLabel() {
        let contents = CleanupAgent.plistContents(scriptPath: "/tmp/agent.sh", appDir: "/tmp/Applications")
        #expect(contents.contains("<string>\(CleanupAgent.label)</string>"))
        #expect(contents.contains("<key>WatchPaths</key>"))
        #expect(contents.contains("<string>/tmp/Applications</string>"))
        #expect(contents.contains("/tmp/agent.sh"))
        #expect(contents.contains("<key>RunAtLoad</key>"))
    }

    /// The script must carry the mis-purge threshold and the complete
    /// cleanup actions — the core of update-flow safety.
    @Test func bundledScriptHasSafetyThresholdAndCleanup() throws {
        let url = try #require(Bundle.main.url(forResource: "cleanup-agent", withExtension: "sh"))
        let script = try String(contentsOf: url, encoding: .utf8)
        #expect(script.contains("THRESHOLD=120"))
        #expect(script.contains(#"if [ -e "$APP" ]"#))
        #expect(script.contains("tccutil reset All com.xiabingquan.voice-doodle"))
        #expect(script.contains("launchctl bootout"))
        #expect(script.contains("Application Support/Voice Doodle"))
    }
}
