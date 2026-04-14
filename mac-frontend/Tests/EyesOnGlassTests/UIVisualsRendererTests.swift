import XCTest
import CoreVideo
@testable import EyesOnGlass

@MainActor
final class UIVisualsRendererTests: XCTestCase {
    var controller = StreamController()
    
    func testRenderVideoFrameZeroCopy() async throws {
        let renderer = UIVisualsRenderer(streamController: controller)
        
        let dummyPixelBuffer: CVPixelBuffer = {
            var pb: CVPixelBuffer?
            let status = CVPixelBufferCreate(kCFAllocatorDefault, 100, 100, kCVPixelFormatType_32BGRA, nil, &pb)
            XCTAssertEqual(status, kCVReturnSuccess)
            return pb!
        }()
        
        controller.isAdvancedInspectorVisible = true
        
        // Assert Subject broadcasts without blockages
        let expectation = expectation(description: "videoFrameSubject should emit CVPixelBuffer")
        let cancellable = controller.videoFrameSubject.sink { value in
            XCTAssertNotNil(value)
            expectation.fulfill()
        }
        
        // Render first frame
        renderer.render(pixelBuffer: dummyPixelBuffer)
        
        // Yield to let Combine subject sync execute
        await fulfillment(of: [expectation], timeout: 1.0)
        cancellable.cancel()
        
        controller.isAdvancedInspectorVisible = false
    }
    
    func testRenderAudioVisualsIsThrottled() async throws {
        let renderer = UIVisualsRenderer(streamController: controller)
        
        controller.isAdvancedInspectorVisible = true
        controller.audioWaveformData = []
        controller.audioVectorscopeData = []
        controller.audioPhaseData = []
        controller.audioLevelsData = []
        
        let dummyWaveform: [Float] = [0.1, 0.2, 0.3]
        let dummyVectorscope: [CGPoint] = [CGPoint(x: 1, y: 1)]
        let dummyPhase: [Float] = [0.5, 0.6]
        let dummyLevels: [Float] = [1.0, 0.8]
        
        // Render first frame
        renderer.render(waveform: dummyWaveform, vectorscope: dummyVectorscope, phase: dummyPhase, levels: dummyLevels)
        
        // Yield to allow async queue dispatches to process
        try await Task.sleep(nanoseconds: 50_000_000) 
        
        XCTAssertEqual(controller.audioWaveformData, dummyWaveform)
        XCTAssertEqual(controller.audioVectorscopeData, dummyVectorscope)
        XCTAssertEqual(controller.audioPhaseData, dummyPhase)
        XCTAssertEqual(controller.audioLevelsData, dummyLevels)
        
        controller.isAdvancedInspectorVisible = false
    }
}
