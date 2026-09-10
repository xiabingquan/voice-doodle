import Foundation
import Testing
@testable import voice_doodle

struct DoubaoFrameTests {
    @Test func startFrameUsesV1Framing() throws {
        let json = Data(#"{"user":{"uid":"x"}}"#.utf8)
        let frame = DoubaoFrame.startFrame(json: json)
        #expect(frame[0] == 0x11)
        #expect(frame[1] == 0x10)   // type 1 << 4 — the V1 layout
        #expect(frame[2] == 0x00)
        #expect(frame[3] == 0x00)
        // 4-byte big-endian length then payload
        let declared = frame.subdata(in: 4..<8).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        #expect(declared == UInt32(json.count))
        #expect(frame.dropFirst(8) == json[...])
    }

    @Test func audioFrameShiftsTypeToHighNibble() {
        let pcm = Data([0x01, 0x02, 0x03])
        let frame = DoubaoFrame.audioFrame(pcm: pcm)
        #expect(frame[1] == 0x20)   // type 2 << 4
        let declared = frame.subdata(in: 4..<8).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        #expect(declared == UInt32(pcm.count))
        #expect(frame.dropFirst(8) == pcm[...])
    }

    @Test func finishFrameSetsLastPacketFlag() {
        let frame = DoubaoFrame.finishFrame()
        #expect(frame == Data([0x11, 0x22, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]))   // type 2<<4 | last-packet, zero length
    }

    @Test func jsonPayloadFindsBraceAcrossHeaderShapes() throws {
        // V1-style: JSON right after the 4-byte header.
        var v1 = Data([0x11, 0x30, 0x00, 0x00])
        v1.append(Data(#"{"result":{"text":"你好"}}"#.utf8))
        #expect(String(data: DoubaoFrame.jsonPayload(from: v1)!, encoding: .utf8)!.contains("你好"))

        // Server error frame: 4-byte header + 8-byte prefix, then JSON.
        var observed = Data([0x11, 0xf0, 0x10, 0x00])
        observed.append(Data([0x02, 0xae, 0xa5, 0x40, 0x00, 0x00, 0x00, 0x68]))
        observed.append(Data(#"{"error":"boom"}"#.utf8))
        let payload = DoubaoFrame.jsonPayload(from: observed)
        #expect(String(data: payload!, encoding: .utf8) == #"{"error":"boom"}"#)

        #expect(DoubaoFrame.jsonPayload(from: Data([0x11, 0x00])) == nil)
    }

    @Test func serverFlagsReadLowNibble() {
        // V1 server byte1 = (type << 4) | flags — only the low nibble is flags.
        #expect(DoubaoFrame.serverFlags(from: Data([0x11, 0x91, 0x00])) == 0x01)   // type 9, pos-sequence
        #expect(DoubaoFrame.serverFlags(from: Data([0x11, 0x93, 0x00])) == 0x03)   // type 9, pos+last
        #expect(DoubaoFrame.serverFlags(from: Data([0x11, 0xf1, 0x00])) == 0x01)   // type 15 (error), flags 1
        #expect(DoubaoFrame.serverFlags(from: Data([0x11])) == nil)
        #expect(DoubaoFrame.serverFlags(from: Data()) == nil)
    }

    @Test func isLastPackageDetectsTerminalFrame() {
        // Final frame: type 0x9 (server full response) with flags 0x3.
        let final = Data([0x11, 0x93, 0x00, 0x00])
        #expect(DoubaoFrame.isLastPackage(final))
        // Progress frames carry flags 0x1 — not terminal.
        let progress = Data([0x11, 0x91, 0x00, 0x00])
        #expect(!DoubaoFrame.isLastPackage(progress))
        // Error frames without the last-packet bit are not terminal either.
        #expect(!DoubaoFrame.isLastPackage(Data([0x11, 0xf1, 0x00, 0x00])))
        // Too short to parse → treated as non-terminal rather than crashing.
        #expect(!DoubaoFrame.isLastPackage(Data([0x11])))
    }

    @Test func resultDecodesLeniently() throws {
        let json = Data(#"{"code":0,"message":"Success","result":{"text":"测试"},"is_interim":false}"#.utf8)
        let result = try JSONDecoder().decode(DoubaoResult.self, from: json)
        #expect(result.result?.text == "测试")
        let err = try JSONDecoder().decode(DoubaoResult.self, from: Data(#"{"error":"bad"}"#.utf8))
        #expect(err.error == "bad")
    }
}
