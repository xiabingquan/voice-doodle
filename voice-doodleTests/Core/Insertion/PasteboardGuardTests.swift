import AppKit
import Testing
@testable import voice_doodle

/// PasteboardGuard unit tests. These exercise the real general pasteboard
/// (there is no injectable seam); each test backs up first and restores in
/// defer, so the developer's clipboard ends unchanged.
@MainActor
struct PasteboardGuardTests {
    @Test func backupWriteRestoreRoundTrip() async {
        let pasteGuard = PasteboardGuard()
        let backup = pasteGuard.backup()
        defer { pasteGuard.restore(backup) }

        let before = pasteGuard.currentChangeCount()
        let after = pasteGuard.writePlainText("vd-pasteboard-test")
        #expect(after > before)
        #expect(NSPasteboard.general.string(forType: .string) == "vd-pasteboard-test")

        pasteGuard.restore(backup)
        if let original = backup.contents[.string] {
            #expect(NSPasteboard.general.data(forType: .string) == original)
        }
    }

    @Test func emptyBackupRestoreIsNoOp() async {
        let pasteGuard = PasteboardGuard()
        let backup = pasteGuard.backup()
        defer { pasteGuard.restore(backup) }

        _ = pasteGuard.writePlainText("vd-temp")
        let mid = pasteGuard.currentChangeCount()
        pasteGuard.restore(PasteboardGuard.Backup(contents: [:]))
        // Empty restore returns early — the written text stays put.
        #expect(NSPasteboard.general.string(forType: .string) == "vd-temp")
        #expect(pasteGuard.currentChangeCount() == mid)
    }
}
