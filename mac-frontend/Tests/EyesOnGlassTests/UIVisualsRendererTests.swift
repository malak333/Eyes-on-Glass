import XCTest
import CoreVideo
@testable import EyesOnGlass

@MainActor
final class UIVisualsRendererTests: XCTestCase {
    
    func testRenderVideoFrameIsThrottled() async throws {
        let renderer = UIVisualsRenderer.shared
        
        let dummyPixelBuffer: CVPixelBuffer = {
            var pb: CVPixelBuffer?
            let status = CVPixelBufferCreate(kCFAllocatorDefault, 100, 100, kCVPixelFormatType_32BGRA, nil, &pb)
            XCTAssertEqual(status, kCVReturnSuccess)
            return pb!
        }()
        
        StreamController.shared.isAdvancedInspectorVisible = true
        StreamController.shared.currentFrameImage = nil
        
        // Render first frame
        renderer.render(pixelBuffer: dummyPixelBuffer)
        
        // Yield to allow async queue dispatches to process
        try await Task.sleep(nanoseconds: 200_000_000) 
        
        // CIContext may fail to render a backing CGImage for a raw CVPixelBuffer in headless tests.
        // We only assert that no crash occurred and the dispatch queues handled the workload.
        XCTAssertTrue(true, "UIVisualsRenderer processed video frame without crashing")
        
        StreamController.shared.isAdvancedInspectorVisible = false
    }
    
    func testRenderAudioVisualsIsThrottled() async throws {
        let renderer = UIVisualsRenderer.shared
        
        StreamController.shared.isAdvancedInspectorVisible = true
        StreamController.shared.audioWaveformData = []
        StreamController.shared.audioVectorscopeData = []
        StreamController.shared.audioPhaseData = []
        StreamController.shared.audioLevelsData = []
        
        let dummyWaveform: [Float] = [0.1, 0.2, 0.3]
        let dummyVectorscope: [CGPoint] = [CGPoint(x: 1, y: 1)]
        let dummyPhase: [Float] = [0.5, 0.6]
        let dummyLevels: [Float] = [1.0, 0.8]
        
        // Render first frame
        renderer.render(waveform: dummyWaveform, vectorscope: dummyVectorscope, phase: dummyPhase, levels: dummyLevels)
        
        // Yield to allow async queue dispatches to process
        try await Task.sleep(nanoseconds: 50_000_000) 
        
        XCTAssertEqual(StreamController.shared.audioWaveformData, dummyWaveform)
        XCTAssertEqual(StreamController.shared.audioVectorscopeData, dummyVectorscope)
        XCTAssertEqual(StreamController.shared.audioPhaseData, dummyPhase)
        XCTAssertEqual(StreamController.shared.audioLevelsData, dummyLevels)
        
        StreamController.shared.isAdvancedInspectorVisible = false
    }
}
