import XCTest
@testable import EyesOnGlass

final class EngineFallbackTests: XCTestCase {
    
    func testLiveStreamServiceDetermineDefaultEngine() {
        // When VLM is not ready, always fallback to opencv
        XCTAssertEqual(LiveStreamService.determineDefaultEngine(isVlmReady: false, frameIndex: 0, tierName: "Gemma 4 E2B"), "opencv")
        XCTAssertEqual(LiveStreamService.determineDefaultEngine(isVlmReady: false, frameIndex: 1, tierName: "Gemma 4 E2B"), "opencv")
        XCTAssertEqual(LiveStreamService.determineDefaultEngine(isVlmReady: false, frameIndex: 5, tierName: "Gemma 4 E2B"), "opencv")
        
        // When VLM is ready, use tierName only on the 5th frame
        XCTAssertEqual(LiveStreamService.determineDefaultEngine(isVlmReady: true, frameIndex: 0, tierName: "Gemma 4 E2B"), "Gemma 4 E2B")
        XCTAssertEqual(LiveStreamService.determineDefaultEngine(isVlmReady: true, frameIndex: 1, tierName: "Gemma 4 E2B"), "opencv")
        XCTAssertEqual(LiveStreamService.determineDefaultEngine(isVlmReady: true, frameIndex: 4, tierName: "Gemma 4 E2B"), "opencv")
        XCTAssertEqual(LiveStreamService.determineDefaultEngine(isVlmReady: true, frameIndex: 5, tierName: "Gemma 4 E2B"), "Gemma 4 E2B")
        XCTAssertEqual(LiveStreamService.determineDefaultEngine(isVlmReady: true, frameIndex: 10, tierName: "Gemma 4 E2B"), "Gemma 4 E2B")
    }
    
    func testExtractionServiceDetermineDefaultEngine() {
        // ExtractionService uses the VLM tier name if ready, else opencv fallback
        XCTAssertEqual(ExtractionService.determineDefaultEngine(isVlmReady: false, tierName: "Gemma 4 E2B"), "opencv")
        XCTAssertEqual(ExtractionService.determineDefaultEngine(isVlmReady: true, tierName: "Gemma 4 E2B"), "Gemma 4 E2B")
    }
}
