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
        XCTAssertEqual(controller.streamFramesAnalyzed, 0)
        XCTAssertNil(controller.currentIAT)
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
            XCTAssertNil(inserted.iatMs)
        } else {
            XCTFail("Could not find the inserted video log")
        }
    }
    
    @MainActor
    func testInsertVideoLogWithIAT() async throws {
        let context = modelContainer.mainContext
        controller.modelContext = context
        
        controller.insertVideoLog(
            videoFilename: "udp://TEST-STREAM-4",
            timestampSec: 101.5,
            nodeSource: "Live-Multicast",
            nodeBackbone: "East",
            nodeDest: "Distribution",
            issueType: "high_iat",
            issueScore: 1.0,
            analysisEngine: "ingestor",
            thumbnailPath: nil,
            iatMs: 45.2
        )
        
        let descriptor = FetchDescriptor<VideoLog>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        let results = try context.fetch(descriptor)
        
        let inserted = results.first(where: { $0.videoFilename == "udp://TEST-STREAM-4" })
        XCTAssertNotNil(inserted)
        XCTAssertEqual(inserted?.iatMs, 45.2)
    }
    
    @MainActor
    func testUpdateIAT() async {
        XCTAssertNil(controller.currentIAT)
        
        controller.updateIAT(12.5)
        XCTAssertEqual(controller.currentIAT, 12.5)
        
        controller.updateIAT(45.2)
        XCTAssertEqual(controller.currentIAT, 45.2)
    }
    
    @MainActor
    func testClearEventsArchivesLogs() async throws {
        let context = modelContainer.mainContext
        controller.modelContext = context
        
        controller.insertVideoLog(
            videoFilename: "udp://TEST-STREAM-CLEAR",
            timestampSec: 1.0,
            nodeSource: "Source",
            nodeBackbone: "Backbone",
            nodeDest: "Dest",
            issueType: "ok",
            issueScore: 1.0,
            analysisEngine: "test",
            thumbnailPath: nil
        )
        
        var descriptor = FetchDescriptor<VideoLog>(predicate: #Predicate { $0.isArchived == false })
        var results = try context.fetch(descriptor)
        XCTAssertEqual(results.count, 1)
        
        controller.clearEvents()
        
        descriptor = FetchDescriptor<VideoLog>(predicate: #Predicate { $0.isArchived == false })
        results = try context.fetch(descriptor)
        XCTAssertEqual(results.count, 0)
        
        let allDescriptor = FetchDescriptor<VideoLog>()
        let allResults = try context.fetch(allDescriptor)
        XCTAssertEqual(allResults.count, 1)
        XCTAssertTrue(allResults.first?.isArchived == true)
    }
    
    @MainActor
    func testClearEventsResetsState() async {
        controller.currentSessionIdentifier = "test-session"
        controller.videoPID = 100
        controller.audioPID = 101
        controller.streamFramesAnalyzed = 500
        controller.streamCCErrors = 5
        controller.totalCCErrors = 5
        controller.streamDuration = 100.0
        controller.connectionStatus = "Disconnected"
        
        controller.clearEvents()
        
        XCTAssertNil(controller.currentSessionIdentifier)
        XCTAssertNil(controller.videoPID)
        XCTAssertNil(controller.audioPID)
        XCTAssertEqual(controller.streamFramesAnalyzed, 0)
        XCTAssertEqual(controller.streamCCErrors, 0)
        XCTAssertEqual(controller.totalCCErrors, 0)
        XCTAssertEqual(controller.streamIP, "-")
    }
    
    @MainActor
    func testVBRDetectionLogic() async {
        XCTAssertFalse(controller.isVBR)
        
        // Simulate constant bitrate (10 Mbps) over 5 intervals
        for _ in 0..<5 {
            // formula: instBitrate = Double(delta) * 1316.0 * 8.0 / elapsed / 1_000_000.0
            // so delta = instBitrate * elapsed * 1_000_000.0 / (1316.0 * 8.0)
            // for 10 Mbps, elapsed 2.0s: delta = 10 * 2_000_000 / 10528 = 1899.69 => ~1900 packets
            controller.updateBitrateHistory(delta: 1900, elapsed: 2.0)
        }
        XCTAssertFalse(controller.isVBR, "Should not detect VBR on stable bitrate")
        
        // Simulate a sudden drop to 8 Mbps (20% fluctuation)
        // delta for 8 Mbps over 2.0s = 8 * 2_000_000 / 10528 = 1519.7 => ~1520 packets
        controller.updateBitrateHistory(delta: 1520, elapsed: 2.0)
        XCTAssertTrue(controller.isVBR, "Should detect VBR when fluctuation > 10%")
        
        // Simulate jitter-based false positive that SHOULD NOT trigger VBR
        // Jitter: elapsed is 1.9s instead of 2.0s, delta is for 10 Mbps (so 10 * 1_900_000 / 10528 = 1804 packets)
        // Since we pass true elapsed time = 1.9s, calculated instBitrate = 1804 * 10528 / 1.9 / 1M ≈ 9.99 Mbps
        controller.updateBitrateHistory(delta: 1804, elapsed: 1.9)
        // Since 9.99 vs 10 is < 10% fluctuation, it correctly stabilizes (if old values fall off)
        // Note: the previous 8 Mbps value is still in the queue (size is 10 max), so isVBR remains true until 8Mbps falls out.
        // Let's flush the queue by feeding 10 Mbps for 10 iterations.
        for _ in 0..<10 {
            controller.updateBitrateHistory(delta: 1900, elapsed: 2.0)
        }
        XCTAssertFalse(controller.isVBR, "VBR flag should reset after stable bitrate returns")
        
        // Feed jitter-affected time window (1.9s)
        controller.updateBitrateHistory(delta: 1804, elapsed: 1.9)
        XCTAssertFalse(controller.isVBR, "True elapsed time calculations should prevent jitter-based VBR detection")
    }
}