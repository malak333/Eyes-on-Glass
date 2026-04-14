import XCTest
import SwiftData
@testable import EyesOnGlass

final class StreamControllerTests: XCTestCase {
    var controller: StreamController!
    var modelContainer: ModelContainer!
    
    @MainActor
    override func setUp() async throws {
        // Create an in-memory SwiftData container for testing
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        modelContainer = try ModelContainer(for: VideoLog.self, configurations: config)
        
        controller = StreamController()
    }
    
    @MainActor
    func testStartMonitoringUpdatesState() async {
        let context = modelContainer.mainContext
        
        XCTAssertEqual(controller.connectionStatus, "Disconnected")
        XCTAssertNil(controller.activeSessionName)
        
        await controller.startMonitoring(uri: "udp://127.0.0.1:4000", context: context)
        
        // Wait briefly for Task to dispatch
        try? await Task.sleep(nanoseconds: 100_000_000)
        
        XCTAssertEqual(controller.connectionStatus, "Active")
        XCTAssertEqual(controller.activeSessionName, "udp://127.0.0.1:4000")
        XCTAssertNotNil(controller.modelContext)
    }
    
    @MainActor
    func testStopMonitoringResetsState() async {
        let context = modelContainer.mainContext
        
        await controller.startMonitoring(uri: "udp://127.0.0.1:4000", context: context)
        
        await controller.stopMonitoring()
        
        XCTAssertEqual(controller.connectionStatus, "Disconnected")
        XCTAssertNil(controller.activeSessionName)
        XCTAssertNil(controller.audioBitrate)
        XCTAssertNil(controller.audioLoudness)
        XCTAssertNil(controller.audioTruePeak)
        XCTAssertNil(controller.audioDialNorm)
    }
    
    @MainActor
    func testInitialHardwareMetrics() async {
        XCTAssertEqual(controller.hardwareCPU, 0.0)
        XCTAssertEqual(controller.hardwareMemory, 0.0)
        XCTAssertEqual(controller.hardwareGPU, 0.0)
    }
    
    @MainActor
    func testSelectedTimeframeState() async {
        XCTAssertEqual(controller.selectedTimeframe, "1m") // Default state
        
        controller.selectedTimeframe = "5m"
        XCTAssertEqual(controller.selectedTimeframe, "5m")
        
        controller.selectedTimeframe = "30m"
        XCTAssertEqual(controller.selectedTimeframe, "30m")
    }
    
    @MainActor
    func testAudioVisualizerStateReset() async {
        let context = modelContainer.mainContext
        await controller.startMonitoring(uri: "udp://127.0.0.1:4000", context: context)
        
        // Mock some visualizer data
        controller.audioWaveformData = [0.5, 0.6, 0.7]
        controller.audioPhaseData = [1.0, 2.0]
        controller.audioVectorscopeData = [CGPoint(x: 1, y: 1)]
        controller.isVBR = true
        
        await controller.stopMonitoring()
        
        // Verify audio visualizer arrays are cleared on stop
        XCTAssertTrue(controller.audioWaveformData.isEmpty)
        XCTAssertTrue(controller.audioPhaseData.isEmpty)
        XCTAssertTrue(controller.audioVectorscopeData.isEmpty)
        XCTAssertFalse(controller.isVBR)
    }
    
    @MainActor
    func testVideoPropertiesDefaultAndCompute() async {
        XCTAssertNil(controller.videoAspect)
        XCTAssertNil(controller.videoFrameRate)
        XCTAssertNil(controller.videoColor)
        XCTAssertNil(controller.videoGOPSize)
        
        // Compute 16:9
        controller.videoResolution = CGSize(width: 1920, height: 1080)
        XCTAssertEqual(controller.videoAspect, "16:9")
        
        // Compute 4:3
        controller.videoResolution = CGSize(width: 720, height: 480)
        XCTAssertEqual(controller.videoAspect, "4:3")
        
        // Compute non-standard
        controller.videoResolution = CGSize(width: 800, height: 600)
        XCTAssertEqual(controller.videoAspect, "800:600")
        
        controller.videoResolution = nil
    }
    
    @MainActor
    func testVisualizerVisibilityToggle() async {
        XCTAssertFalse(controller.isAdvancedInspectorVisible, "Inspector should be hidden by default")
        
        controller.isAdvancedInspectorVisible = true
        XCTAssertTrue(controller.isAdvancedInspectorVisible)
    }
    
    @MainActor
    func testInsertVideoLogWithSummary() async throws {
        let context = modelContainer.mainContext
        controller.modelContext = context
        
        controller.insertVideoLog(
            videoFilename: "udp://TEST-STREAM-3",
            timestampSec: 100.5,
            nodeSource: "VLM-Forensic",
            nodeBackbone: "East",
            nodeDest: "Review",
            issueType: "macroblocking_incident_summary",
            issueScore: 0.99,
            analysisEngine: "Gemma4",
            thumbnailPath: "test_thumb.jpg",
            issueSummary: "Extensive blockation occurred during high motion."
        )
        
        let descriptor = FetchDescriptor<VideoLog>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        let results = try context.fetch(descriptor)
        
        XCTAssertGreaterThanOrEqual(results.count, 1)
        if let inserted = results.first(where: { $0.videoFilename == "udp://TEST-STREAM-3" }) {
            XCTAssertEqual(inserted.issueType, "macroblocking_incident_summary")
            XCTAssertEqual(inserted.issueSummary, "Extensive blockation occurred during high motion.")
        } else {
            XCTFail("Could not find the inserted video log")
        }
    }
}