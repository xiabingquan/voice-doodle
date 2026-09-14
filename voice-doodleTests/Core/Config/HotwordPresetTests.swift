import Foundation
import Testing
@testable import voice_doodle

struct HotwordPresetTests {
    @Test func parseSkipsCommentsBlanksAndDuplicates() {
        let text = """
        # comment line

          词A
        词A
         词B
        #词C
        """
        #expect(HotwordPreset.parse(text) == ["词A", "词B"])
    }

    @Test func loadFromMissingURLIsEmpty() {
        #expect(HotwordPreset.load(from: nil) == [])
    }

    @Test func loadReadsFixtureFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hotwords-\(UUID().uuidString).txt")
        try "# c\n词X\n词Y\n".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(HotwordPreset.load(from: url) == ["词X", "词Y"])
    }
}
