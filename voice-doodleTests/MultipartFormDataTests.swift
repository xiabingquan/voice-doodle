import Testing
import Foundation
@testable import voice_doodle

struct MultipartFormDataTests {
    @Test func fieldBytesExact() {
        var m = MultipartFormData(boundary: "BOUND")
        m.addField(name: "model", value: "whisper-1")
        let expected = "--BOUND\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\nwhisper-1\r\n--BOUND--\r\n"
        #expect(String(data: m.build(), encoding: .utf8) == expected)
    }

    @Test func fileFieldHasContentType() {
        var m = MultipartFormData(boundary: "B")
        m.addFile(name: "file", filename: "record.m4a", mimeType: "audio/mp4", data: Data([0x01, 0x02]))
        let s = String(data: m.build(), encoding: .utf8)!
        #expect(s.contains("Content-Disposition: form-data; name=\"file\"; filename=\"record.m4a\"\r\n"))
        #expect(s.contains("Content-Type: audio/mp4\r\n\r\n"))
        #expect(s.hasSuffix("\r\n--B--\r\n"))
    }

    @Test func chinesePromptRoundTripsUTF8() {
        var m = MultipartFormData(boundary: "B")
        m.addField(name: "prompt", value: "以下是普通话产品讨论")
        let data = m.build()
        let s = String(data: data, encoding: .utf8)!
        #expect(s.contains("以下是普通话产品讨论"))
    }

    @Test func contentTypeIncludesBoundary() {
        let m = MultipartFormData(boundary: "XYZ")
        #expect(m.contentType == "multipart/form-data; boundary=XYZ")
    }
}
