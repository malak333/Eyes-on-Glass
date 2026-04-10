@testable import App
import XCTVapor

final class TSDemuxer_Tests: XCTestCase {
    
    func testTSDemuxerSyncByteAlignment() throws {
        let demuxer = TSDemuxer()
        
        // Create 300 bytes of garbage
        var garbageData = Data(repeating: 0xFF, count: 300)
        
        // Inject a mocked MPEG-TS packet at offset 50
        // standard TS packet is 188 bytes, starts with 0x47
        var validPacket = Data(repeating: 0x00, count: 188)
        validPacket[0] = 0x47 // sync byte
        validPacket[1] = 0x40 // PUSI set to true
        validPacket[2] = 0x11 // PID lower bits
        validPacket[3] = 0x10 // continuity counter
        
        // Replace garbage with our valid packet starting at index 50
        garbageData.replaceSubrange(50..<(50+188), with: validPacket)
        
        let events = demuxer.process(data: garbageData)
        let nalCount = events.reduce(0) { count, event in 
            if case .nalUnit = event { return count + 1 }
            return count
        }
        // With no actual PES video data inside, it won't yield NALs, but it should successfully align and not crash.
        XCTAssertEqual(nalCount, 0)
    }
    
    func testTSDemuxerValidPESExtraction() throws {
        let demuxer = TSDemuxer()
        
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
        _ = demuxer.process(data: validPacket)
        
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
        
        // Inject a second start code inside the second packet payload!
        secondPacket[13] = 0x00
        secondPacket[14] = 0x00
        secondPacket[15] = 0x00
        secondPacket[16] = 0x01
        secondPacket[17] = 0x68 // Another NAL
        
        let events1 = demuxer.process(data: secondPacket)
        let nals1 = events1.compactMap { event -> Data? in
            if case .nalUnit(let data, _, _) = event { return data }
            return nil
        }
        
        XCTAssertEqual(nals1.count, 1)
        // With the trailing zero padding stretching through the payload boundary, length will be payload length + 1
        XCTAssertGreaterThan(nals1.first?.count ?? 0, 100) 
        
        // Let's provide a THIRD packet to trigger the second NAL unit extraction
        var thirdPacket = Data(repeating: 0x00, count: 188)
        thirdPacket[0] = 0x47
        thirdPacket[1] = 0x41
        thirdPacket[2] = 0x00
        thirdPacket[3] = 0x12
        thirdPacket[4] = 0x00
        thirdPacket[5] = 0x00
        thirdPacket[6] = 0x01
        thirdPacket[7] = 0xE0
        thirdPacket[8] = 0x00
        
        thirdPacket[13] = 0x00
        thirdPacket[14] = 0x00
        thirdPacket[15] = 0x00
        thirdPacket[16] = 0x01
        
        let events2 = demuxer.process(data: thirdPacket)
        let nals2 = events2.compactMap { event -> Data? in
            if case .nalUnit(let data, _, _) = event { return data }
            return nil
        }
        
        XCTAssertEqual(nals2.count, 1)
    }
    
    func testTSDemuxerIndexShiftingSafety() throws {
        // This test validates that TSDemuxer correctly utilizes bounded indices (startIndex / endIndex)
        // when manipulating interior Data buffers, preventing BPT traps when 'removeSubrange' shifts the pointer.
        let demuxer = TSDemuxer()
        
        // Construct a TS packet sequence that embeds multiple tightly-packed NAL units to force consecutive removals.
        var validPacket = Data(repeating: 0x00, count: 188)
        validPacket[0] = 0x47
        validPacket[1] = 0x41
        validPacket[2] = 0x00
        validPacket[3] = 0x10
        // PES Header
        validPacket[4] = 0x00
        validPacket[5] = 0x00
        validPacket[6] = 0x01
        validPacket[7] = 0xE0
        validPacket[8] = 0x00
        validPacket[9] = 0x00
        validPacket[10] = 0x80
        validPacket[11] = 0x00
        validPacket[12] = 0x00
        
        // Plumb multiple NAL units into a single PES payload payload index 13:
        validPacket[13] = 0x00
        validPacket[14] = 0x00
        validPacket[15] = 0x00
        validPacket[16] = 0x01
        validPacket[17] = 0x11 // NAL 1
        
        validPacket[18] = 0x00
        validPacket[19] = 0x00
        validPacket[20] = 0x00
        validPacket[21] = 0x01
        validPacket[22] = 0x22 // NAL 2
        
        validPacket[23] = 0x00
        validPacket[24] = 0x00
        validPacket[25] = 0x00
        validPacket[26] = 0x01
        validPacket[27] = 0x33 // NAL 3
        
        let events1 = demuxer.process(data: validPacket)
        
        // Provide termination NAL unit in the next packet
        var second = Data(repeating: 0x00, count: 188)
        second[0] = 0x47
        second[1] = 0x41
        second[2] = 0x00
        second[3] = 0x11
        second[4] = 0x00; second[5] = 0x00; second[6] = 0x01; second[7] = 0xE0; second[10] = 0x80
        second[13] = 0x00; second[14] = 0x00; second[15] = 0x00; second[16] = 0x01
        
        let events2 = demuxer.process(data: second)
        
        var emittedNalUnits: [Data] = []
        for event in (events1 + events2) {
            if case .nalUnit(let nal, _, _) = event {
                emittedNalUnits.append(nal)
            }
        }
        
        XCTAssertEqual(emittedNalUnits.count, 3)
        // Verify start codes are correctly bounded natively for second and third chunks
        if emittedNalUnits.count >= 3 {
             XCTAssertEqual([UInt8](emittedNalUnits[0])[4], 0x11)
             XCTAssertEqual([UInt8](emittedNalUnits[1])[4], 0x22)
             XCTAssertEqual([UInt8](emittedNalUnits[2])[4], 0x33)
        }
    }
    
    func testTSDemuxerAudio0xBDExtraction() throws {
        // Enforces Code Style Guide Rule 1: Automated testing for the audio detection fix.
        // Validates that Private Stream 1 (0xBD), commonly used for AC-3 audio, is correctly identified as an audio stream.
        let demuxer = TSDemuxer()
        
        var audioPacket = Data(repeating: 0x00, count: 188)
        audioPacket[0] = 0x47
        audioPacket[1] = 0x41
        audioPacket[2] = 0x01 // PID = 0x0101
        audioPacket[3] = 0x10
        
        // PES Header for Audio (0xBD - Private Stream 1)
        audioPacket[4] = 0x00
        audioPacket[5] = 0x00
        audioPacket[6] = 0x01
        audioPacket[7] = 0xBD // stream_id 0xBD (AC-3 Audio)
        audioPacket[8] = 0x00
        audioPacket[9] = 0x00
        audioPacket[10] = 0x80
        audioPacket[11] = 0x00
        audioPacket[12] = 0x00
        
        // Payload
        audioPacket[13] = 0x01
        audioPacket[14] = 0x02
        audioPacket[15] = 0x03
        
        // We will send this packet, then we MUST send a second PES packet to flush the buffer
        let events1 = demuxer.process(data: audioPacket)
        
        var secondPacket = Data(repeating: 0x00, count: 188)
        secondPacket[0] = 0x47
        secondPacket[1] = 0x41 // Trigger buffer flush
        secondPacket[2] = 0x01 // Same PID
        secondPacket[3] = 0x11
        secondPacket[4] = 0x00; secondPacket[5] = 0x00; secondPacket[6] = 0x01; secondPacket[7] = 0xBD
        
        let events2 = demuxer.process(data: secondPacket)
        
        var emittedAudioFrames: [Data] = []
        for event in (events1 + events2) {
            if case .audio(let frame, _) = event {
                emittedAudioFrames.append(frame)
            }
        }
        
        // Should find 2 audio frames since both packets had PES payloads
        XCTAssertEqual(emittedAudioFrames.count, 2)
        if let firstAudio = emittedAudioFrames.first {
            let firstAudioArray = [UInt8](firstAudio)
            XCTAssertGreaterThanOrEqual(firstAudioArray.count, 3)
            XCTAssertEqual(firstAudioArray[0], 0x01)
            XCTAssertEqual(firstAudioArray[1], 0x02)
            XCTAssertEqual(firstAudioArray[2], 0x03)
        }
    }
}
