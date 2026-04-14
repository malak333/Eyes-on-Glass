import XCTest
import CoreVideo
import AVFoundation
import Combine
@testable import EyesOnGlass

@MainActor
final class SampleBufferVideoViewTests: XCTestCase {
    
    func testCoordinatorEnqueue() throws {
        // Given
        let coordinator = SampleBufferVideoView(frameStream: Empty<CVPixelBuffer, Never>().eraseToAnyPublisher()).makeCoordinator()
        
        let dummyPixelBuffer: CVPixelBuffer = {
            var pb: CVPixelBuffer?
            let status = CVPixelBufferCreate(kCFAllocatorDefault, 100, 100, kCVPixelFormatType_32BGRA, nil, &pb)
            XCTAssertEqual(status, kCVReturnSuccess)
            return pb!
        }()
        
        // When
        coordinator.enqueue(pixelBuffer: dummyPixelBuffer)
        
        // Then
        // AVSampleBufferDisplayLayer handles exact rendering asynchronously,
        // but we can assert the status didn't immediately move to failed.
        XCTAssertTrue(coordinator.displayLayer.status != .failed, "Display layer status should not be failed after enqueue.")
    }
}

