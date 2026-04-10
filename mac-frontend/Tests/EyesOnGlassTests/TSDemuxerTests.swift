import XCTest
@testable import EyesOnGlass

final class TSDemuxerTests: XCTestCase {
    
    func createTSPacket(pid: UInt16, pcrBase: UInt64) -> Data {
        var packet = Data(repeating: 0, count: 188)
        packet[0] = 0x47
        packet[1] = UInt8((pid >> 8) & 0x1F)
        packet[2] = UInt8(pid & 0xFF)
        packet[3] = 0x20 // Adaptation field only, continuity counter 0
        packet[4] = 7 // Adaptation length
        packet[5] = 0x10 // PCR flag set
        
        packet[6] = UInt8((pcrBase >> 25) & 0xFF)
        packet[7] = UInt8((pcrBase >> 17) & 0xFF)
        packet[8] = UInt8((pcrBase >> 9) & 0xFF)
        packet[9] = UInt8((pcrBase >> 1) & 0xFF)
        packet[10] = UInt8((pcrBase & 1) << 7) | 0x7E // Reserve bits
        packet[11] = 0x00 // PCR Extension
        
        return packet
    }
    
    func testPCRParsing() {
        let demuxer = TSDemuxer()
        
        // 1 second in 90kHz
        let packet1 = createTSPacket(pid: 256, pcrBase: 90_000)
        _ = demuxer.process(data: packet1)
        
        XCTAssertEqual(demuxer.currentTsClock, "00:00:01.000")
        XCTAssertNil(demuxer.currentPcrInterval)
        XCTAssertNil(demuxer.currentPcrJitter)
        
        // Sleep a little bit to create a real interval for the Date().timeIntervalSince1970 diff
        Thread.sleep(forTimeInterval: 0.1)
        
        // 1.1 seconds in 90kHz
        let packet2 = createTSPacket(pid: 256, pcrBase: 99_000)
        _ = demuxer.process(data: packet2)
        
        XCTAssertEqual(demuxer.currentTsClock, "00:00:01.100")
        
        // Interval should be around 100ms
        let interval = demuxer.currentPcrInterval
        XCTAssertNotNil(interval)
        XCTAssertTrue(interval! > 50.0 && interval! < 150.0)
        
        // Jitter should be small since the real sleep matches the PCR increment roughly
        let jitter = demuxer.currentPcrJitter
        XCTAssertNotNil(jitter)
        XCTAssertTrue(jitter! >= 0.0)
    }
}
