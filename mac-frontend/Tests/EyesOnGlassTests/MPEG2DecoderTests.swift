import XCTest
@testable import EyesOnGlass

final class MPEG2DecoderTests: XCTestCase {
    
    func testSequenceHeaderParsing() {
        let decoder = MPEG2Decoder()
        
        // Mock MPEG-2 Sequence Header (00 00 01 B3)
        // Width: 1920 (0x780) -> b4: 0x78, b5 (high 4): 0x0
        // Height: 1080 (0x438) -> b5 (low 4): 0x4, b6: 0x38
        let mockPayload: [UInt8] = [
            0x00, 0x00, 0x01, 0xB3,
            0x78, 0x04, 0x38,
            0x00, 0x00, 0x00 // Padding
        ]
        
        decoder.decode(data: Data(mockPayload), pts: 90000, dts: 90000)
        
        // Feed a mock slice so the decoder marks `currentFrameHasSlices = true`
        decoder.decode(data: Data([0x00, 0x00, 0x01, 0x01]), pts: 90000, dts: 90000)
        
        // Feed next frame (Picture Header) to trigger the flush of the accumulation buffer
        decoder.decode(data: Data([0x00, 0x00, 0x01, 0x00]), pts: 93003, dts: 93003)
        XCTAssertNotNil(decoder.videoSize, "Video size should be parsed from Sequence Header")
        XCTAssertEqual(decoder.videoSize?.width, 1920)
        XCTAssertEqual(decoder.videoSize?.height, 1080)
        
        // Verify public properties
        XCTAssertEqual(decoder.videoColor, "ITU-R BT.709")
        XCTAssertEqual(decoder.gopSize, 15)
        XCTAssertEqual(decoder.frameRate, 29.97)
        
        // Verify state clearing
        decoder.reset()
        XCTAssertNil(decoder.videoSize, "Video size should be nil after reset")
    }
}
