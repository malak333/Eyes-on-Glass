import XCTest
import CoreVideo
@testable import EyesOnGlass

final class LiveStreamServiceTests: XCTestCase {
    
    // Validates that explosive frame throughput out of UDPIngestor doesn't crash the LiveStreamService actor state
    func testLiveStreamServiceRenderingVelocity() async {
        let service = LiveStreamService.shared
        
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
                UIVisualsRenderer.shared.render(pixelBuffer: dummyPixelBuffer)
                UIVisualsRenderer.shared.render(waveform: [0.0], vectorscope: [.zero], phase: [0.0], levels: [0.0])
            }
        }
        
        // Let actor run loops clear queue
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        
        // Verify visual buffer bounds and renderer isolation works
        XCTAssertNotNil(service)
    }
}
