@testable import App
import XCTVapor

final class TSDemuxer_Tests: XCTestCase {
    
    // A mock delegate to capture NAL units emitted by our demuxer
    class MockDemuxerDelegate: TSDemuxerDelegate {
        var emittedNalUnits: [Data] = []
        var discontinuityCount = 0
        
        func demuxer(_ demuxer: TSDemuxer, didExtractNALUnit nalUnit: Data) {
            emittedNalUnits.append(nalUnit)
        }
        
        func demuxerDidDetectDiscontinuity(_ demuxer: TSDemuxer) {
            discontinuityCount += 1
        }
    }
    
    func testTSDemuxerSyncByteAlignment() throws {
        let demuxer = TSDemuxer()
        let delegate = MockDemuxerDelegate()
        demuxer.delegate = delegate
        
        // Create 200 bytes of garbage
        var garbageData = Data(repeating: 0xFF, count: 200)
        
        // Inject a mocked MPEG-TS packet at offset 50
        // standard TS packet is 188 bytes, starts with 0x47
        var validPacket = Data(repeating: 0x00, count: 188)
        validPacket[0] = 0x47 // sync byte
        validPacket[1] = 0x40 // PUSI set to true
        validPacket[2] = 0x11 // PID lower bits
        validPacket[3] = 0x10 // continuity counter
        
        // Replace garbage with our valid packet starting at index 50
        garbageData.replaceSubrange(50..<(50+188), with: validPacket)
        
        demuxer.process(data: garbageData)
        // With no actual PES video data inside, it won't yield NALs, but it should successfully align and not crash.
        XCTAssertEqual(delegate.emittedNalUnits.count, 0)
    }
    
    func testTSDemuxerValidPESExtraction() throws {
        let demuxer = TSDemuxer()
        let delegate = MockDemuxerDelegate()
        demuxer.delegate = delegate
        
        // Mock a single TS Packet that includes a PES Header and a raw NAL unit.
        var validPacket = Data(repeating: 0x00, count: 188)
        validPacket[0] = 0x47 // sync byte
        validPacket[1] = 0x41 // PUSI = 1, PID = 0x01
        validPacket[2] = 0x00 // PID = 0x0100
        validPacket[3] = 0x10 // Payload only, cc=0
        
        // PES header for Video (0xE0) starts at byte 4
        validPacket[4] = 0x00 // Start code prefixes for PES
        validPacket[5] = 0x00
        validPacket[6] = 0x01
        validPacket[7] = 0xE0 // stream_id 0xE0 (Video)
        
        validPacket[8] = 0x00 // PES packet length
        validPacket[9] = 0x00 
        
        validPacket[10] = 0x80 // Optional PES header markers
        validPacket[11] = 0x00 
        validPacket[12] = 0x00 // PES header data length = 0
        
        // PES payload starts at index 13
        // Let's inject an H264 start code and NAL unit
        validPacket[13] = 0x00
        validPacket[14] = 0x00
        validPacket[15] = 0x00
        validPacket[16] = 0x01
        validPacket[17] = 0x67 // Sample NAL byte
        validPacket[18] = 0xFF 
        
        // We will send this packet, then we MUST send a second PES packet
        // because the demuxer finishes gathering a PES payload when it sees the NEXT PUSI flag.
        demuxer.process(data: validPacket)
        
        var secondPacket = Data(repeating: 0x00, count: 188)
        secondPacket[0] = 0x47
        secondPacket[1] = 0x41 // Another PUSI to trigger extraction
        secondPacket[2] = 0x00
        secondPacket[3] = 0x11
        secondPacket[4] = 0x00
        secondPacket[5] = 0x00
        secondPacket[6] = 0x01
        secondPacket[7] = 0xE0
        secondPacket[8] = 0x00
        secondPacket[9] = 0x00
        secondPacket[10] = 0x80
        secondPacket[11] = 0x00
        secondPacket[12] = 0x00
        
        demuxer.process(data: secondPacket)
        
        XCTAssertEqual(delegate.emittedNalUnits.count, 1)
        XCTAssertEqual(delegate.emittedNalUnits.first?.count, 2) // Should contain our 0x67 0xFF byte ignoring start codes
    }
}
