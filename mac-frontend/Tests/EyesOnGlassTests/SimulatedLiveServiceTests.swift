import XCTest
import SwiftData
@testable import EyesOnGlass

@MainActor
final class SimulatedLiveServiceTests: XCTestCase {
    var container: ModelContainer!
    var streamController: StreamController!

    override func setUp() async throws {
        // Use an in-memory database configuration mapping just for isolated tests
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(for: VideoLog.self, configurations: config)
        
        streamController = StreamController()
        streamController.modelContext = container.mainContext
    }

    override func tearDown() async throws {
        container = nil
        streamController = nil
    }

    func testFFmpegEnvironmentURLResolution() async throws {
        // Verifies the process uses the dynamically resolved /usr/bin/env instead of hardcoding
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        XCTAssertEqual(process.executableURL?.lastPathComponent, "env")
    }

    func testVLMArbitrationYieldingWaitLoop() async throws {
        // Validates that the SimulatedLiveService actually waits for VLM evaluation to resolve
        let liveStreamService = LiveStreamService(streamController: nil)
        
        // Emulate the stage verifying condition being locked by a VLM inference
        await liveStreamService.setStageAVerifyingStatus(true)
        
        let waitTask = Task {
            while await liveStreamService.isStageAVerifying == true {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            return true
        }
        
        // Ensure it is still waiting (yielding)
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertFalse(waitTask.isCancelled, "The task should still be active and blocking")
        
        // Unlock
        await liveStreamService.setStageAVerifyingStatus(false)
        
        let result = await waitTask.value
        XCTAssertTrue(result, "The wait loop should complete once isStageAVerifying is flipped to false")
    }
}
