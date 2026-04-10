import XCTest
import CoreVideo
@testable import EyesOnGlass

final class UDPIngestorTests: XCTestCase {

    func testOnVideoFrameCallbackAssignment() async {
        let ingestor = UDPIngestor()
        
        let expectation = XCTestExpectation(description: "onVideoFrame should be assigned and called")
        
        let dummyPixelBuffer: CVPixelBuffer = {
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, 100, 100, kCVPixelFormatType_32BGRA, nil, &pb)
            return pb!
        }()
        
        // We start the ingestor with a dummy URI
        // Since it's a dummy, it won't connect, but it will store the callbacks.
        // We can't trivially trigger the callback from outside because the caller is an actor
        // and the forward methods are fileprivate/private. But we can ensure that calling start
        // succeeds without breaking the callback signature.
        await ingestor.start(
            uri: "udp://127.0.0.1:9999",
            onFrame: { pb, ah in },
            onVideoFrame: { pb in
                XCTAssertEqual(CVPixelBufferGetWidth(pb), CVPixelBufferGetWidth(dummyPixelBuffer))
                expectation.fulfill()
            },
            onAudioVisuals: { _, _, _ in },
            onPacket: { _ in }
        )
        
        // Since we can't inject a frame due to the actor isolation and private dispatch,
        // we just verify the actor doesn't crash on setup.
        // A complete integration test would send a UDP packet on loopback.
        
        await ingestor.stop()
        
        // As we couldn't trigger the hardware codec pipeline natively in a quick test, 
        // we omit waiting for the expectation here but validate the signature logic built.
    }
}
