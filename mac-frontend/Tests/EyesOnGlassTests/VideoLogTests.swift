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
            issueType: "macroblocking_incident_summary",
            issueScore: 0.95,
            analysisEngine: "ollama",
            thumbnailPath: "live_12345_abc.jpg",
            issueSummary: "Detailed forensic summary text goes here."
        )
        
        context.insert(log)
        try context.save()
        
        let descriptor = FetchDescriptor<VideoLog>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        let results = try context.fetch(descriptor)
        
        XCTAssertGreaterThanOrEqual(results.count, 1)
        if let inserted = results.first(where: { $0.videoFilename == "udp://TEST-STREAM-2" }) {
            XCTAssertEqual(inserted.thumbnailPath, "live_12345_abc.jpg")
            XCTAssertEqual(inserted.issueSummary, "Detailed forensic summary text goes here.")
        } else {
            XCTFail("Could not find the inserted video log")
        }
    }

    @MainActor
    func testVideoLogWithOptionalMetrics() throws {
        let context = modelContainer.mainContext
        
        let log = VideoLog(
            videoFilename: "udp://TEST-STREAM-3",
            timestampSec: 80.123,
            issueType: "high_iat",
            issueScore: 1.0,
            analysisEngine: "ingestor",
            thumbnailPath: "live_12345_xyz.jpg",
            issueSummary: "IAT spiked to 45.0 ms",
            iatMs: 45.0,
            boundingBoxes: "[0, 0, 100, 100]"
        )
        
        context.insert(log)
        try context.save()
        
        let descriptor = FetchDescriptor<VideoLog>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        let results = try context.fetch(descriptor)
        
        if let inserted = results.first(where: { $0.videoFilename == "udp://TEST-STREAM-3" }) {
            XCTAssertEqual(inserted.iatMs, 45.0)
            XCTAssertEqual(inserted.boundingBoxes, "[0, 0, 100, 100]")
        } else {
            XCTFail("Could not find the inserted video log")
        }
    }

    @MainActor
    func testVideoLogDatabaseDeletion() throws {
        let context = modelContainer.mainContext
        
        let archivedLog = VideoLog(
            videoFilename: "udp://TEST-STREAM-ARCHIVED",
            timestampSec: 10.0,
            issueType: "ok",
            isArchived: true
        )
        
        let activeLog = VideoLog(
            videoFilename: "udp://TEST-STREAM-ACTIVE",
            timestampSec: 20.0,
            issueType: "ok",
            isArchived: false
        )
        
        context.insert(archivedLog)
        context.insert(activeLog)
        try context.save()
        
        // Fetch all archived logs
        let descriptor = FetchDescriptor<VideoLog>(predicate: #Predicate { $0.isArchived == true })
        let archivedLogs = try context.fetch(descriptor)
        
        XCTAssertEqual(archivedLogs.count, 1)
        
        // Emulate the deleteDatabase() logic
        for log in archivedLogs {
            context.delete(log)
        }
        try context.save()
        
        // Verification
        let finalArchivedDescriptor = FetchDescriptor<VideoLog>(predicate: #Predicate { $0.isArchived == true })
        let finalArchivedLogs = try context.fetch(finalArchivedDescriptor)
        XCTAssertEqual(finalArchivedLogs.count, 0)
        
        let allDescriptor = FetchDescriptor<VideoLog>()
        let allLogs = try context.fetch(allDescriptor)
        XCTAssertEqual(allLogs.count, 1)
        XCTAssertEqual(allLogs.first?.videoFilename, "udp://TEST-STREAM-ACTIVE")
    }
}

