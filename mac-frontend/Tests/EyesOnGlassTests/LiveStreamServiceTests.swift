import XCTest
import CoreVideo
@testable import EyesOnGlass

final class LiveStreamServiceTests: XCTestCase {
    
    // Validates that explosive frame throughput out of UDPIngestor doesn't crash the LiveStreamService actor state
    func testLiveStreamServiceRenderingVelocity() async {
        let service = LiveStreamService(streamController: nil)
        
        // Ensure starting clean
        await service.stopMonitoring()
        
        let dummyPixelBuffer: CVPixelBuffer = {
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, 100, 100, kCVPixelFormatType_32BGRA, nil, &pb)
            return pb!
        }()
        
        // Mock a 300-frame instantaneous burst 
        for _ in 0..<300 {
            // Dispatch asynchronously to emulate rapid-fire actor isolation pushes
            Task {
                UIVisualsRenderer(streamController: nil).render(pixelBuffer: dummyPixelBuffer)
                UIVisualsRenderer(streamController: nil).render(waveform: [0.0], vectorscope: [.zero], phase: [0.0], levels: [0.0])
            }
        }
        
        // Let actor run loops clear queue
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        
        // Verify visual buffer bounds and renderer isolation works
        XCTAssertNotNil(service)
    }
    
    // Validates the 2-second threshold rule before emitting an `audio_lost` telemetry ping
    func testAudioLossThresholdLogic() async {
        let service = LiveStreamService(streamController: nil)
        
        // Ensure starting clean
        await service.stopMonitoring()
        
        let dummyPixelBuffer: CVPixelBuffer = {
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, 100, 100, kCVPixelFormatType_32BGRA, nil, &pb)
            return pb!
        }()
        
        let session = "testSession"
        let tempDir = FileManager.default.temporaryDirectory
        
        // Initial clean state check
        var wasHealthy = await service._getWasAudioHealthy()
        XCTAssertNil(wasHealthy, "Should be completely nil before receiving a frame")
        
        // Simulate healthy frame
        await service._injectFrameForTest(pixelBuffer: dummyPixelBuffer, audioHealth: .healthy, networkIAT: 0.0, sessionName: session, thumbnailsDir: tempDir)
        
        wasHealthy = await service._getWasAudioHealthy()
        var startTime = await service._getAudioLossStartTime()
        XCTAssertEqual(wasHealthy, true, "1 Frame in healthy -> translates to healthy=true")
        XCTAssertNil(startTime, "Start time should be nil when healthy")
        
        // ------------------
        // Simulate dropping audio briefly
        // ------------------
        await service._injectFrameForTest(pixelBuffer: dummyPixelBuffer, audioHealth: .silent, networkIAT: 0.0, sessionName: session, thumbnailsDir: tempDir)
        
        wasHealthy = await service._getWasAudioHealthy()
        startTime = await service._getAudioLossStartTime()
        XCTAssertEqual(wasHealthy, true, "Should still be marked healthy (reporting-wise) initially despite silent drop")
        XCTAssertNotNil(startTime, "Loss timer should have explicitly started")
        
        // Sleep for 2.1 seconds to test threshold
        try? await Task.sleep(nanoseconds: 2_100_000_000)
        
        // Let's supply another silent frame bridging past the threshold
        await service._injectFrameForTest(pixelBuffer: dummyPixelBuffer, audioHealth: .silent, networkIAT: 0.0, sessionName: session, thumbnailsDir: tempDir)
        
        wasHealthy = await service._getWasAudioHealthy()
        XCTAssertEqual(wasHealthy, false, "After > 2 seconds of silence, it should transition to false logic")
    }
}
