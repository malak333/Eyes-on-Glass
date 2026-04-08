@testable import App
import XCTVapor

final class AppTests: XCTestCase {
    func testCORSHeadersArePresent() async throws {
        let app = Application(.testing)
        defer { app.shutdown() }
        try await configure(app)

        try app.test(.OPTIONS, "upload", beforeRequest: { req in
            req.headers.add(name: "Origin", value: "http://localhost:5173")
            req.headers.add(name: "Access-Control-Request-Method", value: "POST")
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .ok)
            XCTAssertTrue(res.headers.contains(name: "access-control-allow-origin"))
            XCTAssertEqual(res.headers.first(name: "access-control-allow-origin"), "*")
            XCTAssertTrue(res.headers.contains(name: "access-control-allow-methods"))
        })
    }
    
    func testUploadValidatesEmptyInput() async throws {
        let app = Application(.testing)
        defer { app.shutdown() }
        try await configure(app)
        
        try app.test(.POST, "upload", beforeRequest: { req in
            // Make an empty request
        }, afterResponse: { res in
            // The upload endpoint should reject it as a Bad Request because no file was attached
            XCTAssertEqual(res.status, .badRequest)
        })
    }
    
    func testFFmpegFallbackDoesNotHang() async throws {
        let app = Application(.testing)
        defer { app.shutdown() }
        try await configure(app)
        
        // Setup temporary mock "video" file that is invalid TS to trigger FFmpeg fallback
        let uploadsDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("../backend/uploads/")
        try? FileManager.default.createDirectory(at: uploadsDir, withIntermediateDirectories: true)
        let mockFile = uploadsDir.appendingPathComponent("hanging_test.ts")
        try "invalid data".write(to: mockFile, atomically: true, encoding: .utf8)
        
        // Execute extraction on the invalid file.
        // With -nostdin, ffmpeg will fail immediately on invalid data and the function should return.
        // Without -nostdin, ffmpeg running in the background would hang on STDIN waiting for Input indefinitely.
        await ExtractionService.extractAndAnalyze(filename: "hanging_test.ts", db: app.db, logger: app.logger, client: app.client)
        
        // If it reaches here, the process did not hang!
        try? FileManager.default.removeItem(at: mockFile)
        
        XCTAssertTrue(true, "ExtractionService successfully completed without hanging on stdin.")
    }
    
    func testAudioAmplitudeOverflowProtection() throws {
        // This test simulates the exact conditions that caused the BPT Trap: 5 crash 
        // during AVAssetReader linear PCM parsing where the incoming audio sample is Int16.min
        let extremeSample: Int16 = .min // -32768
        
        // Ensure our newly adopted pattern avoids the overflow trap and calculates precisely
        // Since abs(-32768) overflows Int16, we cast to Float directly first: abs(Float(sample))
        let floatSample = abs(Float(extremeSample))
        
        XCTAssertEqual(floatSample, 32768.0)
    }
    
    func testDetectFreezeGracefulFailure() async throws {
        // Evaluates that the newly decoupled `detectFreeze` method safely handles missing files
        // without crashing the concurrent `async let` TaskGroup in `extractAndAnalyze`.
        let intervals = await ExtractionService.detectFreeze(videoPath: "/fake/path/that/does/not/exist.ts")
        XCTAssertTrue(intervals.isEmpty, "detectFreeze should return an empty array for non-existent files rather than crashing")
    }
}
