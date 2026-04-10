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
}