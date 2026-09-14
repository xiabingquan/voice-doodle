import Foundation
import Testing
@testable import voice_doodle

struct DoubaoHotwordCapTests {
    @Test func capTrimsDedupesAndPreservesOrder() {
        let capped = DoubaoClient.cappedHotwords(
            [" 词A ", "", "词B", "词A", "词C"],
            wsURL: ASRBuiltIns.doubaoWsURL
        )
        #expect(capped == ["词A", "词B", "词C"])
    }

    @Test func capNostreamAllows5000() {
        let words = (0..<5001).map { "词\($0)" }
        #expect(DoubaoClient.cappedHotwords(words, wsURL: ASRBuiltIns.doubaoWsURL).count == 5000)
    }

    @Test func capStreamingDropsTo100() {
        let streamURL = URL(string: "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel")!
        let words = (0..<150).map { "词\($0)" }
        #expect(DoubaoClient.cappedHotwords(words, wsURL: streamURL).count == 100)
    }

    // MARK: - Start frame

    @Test func startFrameOmitsCorpusWhenNoHotwords() throws {
        let data = DoubaoClient.startRequestBody(enablePunc: true, enableITN: true, enableDDC: true)
        let body = String(data: data, encoding: .utf8) ?? ""
        #expect(body.contains("\"enable_punc\":true"))
        #expect(!body.contains("corpus"))
    }

    @Test func startFrameCarriesHotwordsAsEscapedContextString() throws {
        let data = DoubaoClient.startRequestBody(
            enablePunc: true, enableITN: true, enableDDC: true,
            hotwords: ["热词1号", "Voice Doodle"]
        )
        let frame = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let request = try #require(frame["request"] as? [String: Any])
        let corpus = try #require(request["corpus"] as? [String: Any])
        let context = try #require(corpus["context"] as? String)
        let inner = try #require(try JSONSerialization.jsonObject(with: Data(context.utf8)) as? [String: Any])
        let words = try #require(inner["hotwords"] as? [[String: Any]])
        #expect(words.count == 2)
        #expect(words.compactMap { $0["word"] as? String } == ["热词1号", "Voice Doodle"])
        #expect((frame["audio"] as? [String: Any])?["rate"] as? Int == 16000)
    }
}
