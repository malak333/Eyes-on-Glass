import XCTest
import SwiftData
@testable import EyesOnGlass

final class VideoLogTests: XCTestCase {
    var modelContainer: ModelContainer!
    
    @MainActor
    override func setUp() async throws {
        // Create an in-memory SwiftData container for testing
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        modelContainer = try ModelContainer(for: VideoLog.self, configurations: config)
    }
    
    @MainActor
    func testVideoLogInsertion() throws {
        let context = modelContainer.mainContext
        
        let log = VideoLog(
            videoFilename: "udp://TEST-STREAM",
            timestampSec: 55.432,
            issueType: "macroblocking",
            issueScore: 0.88,
            analysisEngine: "ollama"
        )
        
        context.insert(log)
        try context.save()
        
        let descriptor = FetchDescriptor<VideoLog>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        let results = try context.fetch(descriptor)
        
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.videoFilename, "udp://TEST-STREAM")
        XCTAssertEqual(results.first?.issueType, "macroblocking")
        XCTAssertEqual(results.first?.issueScore, 0.88)
        XCTAssertEqual(results.first?.timestampSec, 55.432)
    }

    @MainActor
    func testVideoLogWithThumbnailInsertion() throws {
        let context = modelContainer.mainContext
        
        let log = VideoLog(
            videoFilename: "udp://TEST-STREAM-2",
            timestampSec: 60.123,
            issueType: "blur",
            issueScore: 0.95,
            analysisEngine: "ollama",
            thumbnailPath: "live_12345_abc.jpg"
        )
        
        context.insert(log)
        try context.save()
        
        let descriptor = FetchDescriptor<VideoLog>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        let results = try context.fetch(descriptor)
        
        XCTAssertGreaterThanOrEqual(results.count, 1)
        if let inserted = results.first(where: { $0.videoFilename == "udp://TEST-STREAM-2" }) {
            XCTAssertEqual(inserted.thumbnailPath, "live_12345_abc.jpg")
        } else {
            XCTFail("Could not find the inserted video log")
        }
    }
}
