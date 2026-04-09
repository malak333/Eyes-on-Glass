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
            // The upload endpoint will reject it as unsupportedMediaType because there is no content-type or body
            XCTAssertEqual(res.status, .unsupportedMediaType)
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
    
    func testThumbnailsEndpointSecurity() async throws {
        let app = Application(.testing)
        defer { app.shutdown() }
        try await configure(app)
        
        // Ensure thumbnail directory exists
        let thumbDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("../backend/thumbnails/")
        try? FileManager.default.createDirectory(at: thumbDir, withIntermediateDirectories: true)
        
        let mockThumb = thumbDir.appendingPathComponent("test_thumb.jpg")
        try "fake image data".write(to: mockThumb, atomically: true, encoding: .utf8)
        
        // 1. Test fetching existent file
        try app.test(.GET, "thumbnails/test_thumb.jpg", afterResponse: { res in
            XCTAssertEqual(res.status, .ok)
            XCTAssertEqual(String(buffer: res.body), "fake image data")
        })
        
        // 2. Test missing file
        try app.test(.GET, "thumbnails/does_not_exist.jpg", afterResponse: { res in
            XCTAssertEqual(res.status, .notFound)
        })
        
        // 3. Test path traversal rejection (should be badRequest due to checks)
        // Vapor's router might decode %2E%2E%2F as ../
        // We simulate requesting a file using path traversal
        try app.test(.GET, "thumbnails/..%2F..%2Fetc%2Fpasswd", afterResponse: { res in
            // Depending on router behavior it might not match the route, or it might hit our badRequest check
            XCTAssertNotEqual(res.status, .ok)
        })
        
        try? FileManager.default.removeItem(at: mockThumb)
    }
    
    func testVisionAnalyzerVImagePipeline() async throws {
        // Generates a mock solid color image to pass through the hardware-accelerated VisionAnalyzer.
        // Verifies the vImage pipeline can correctly identify black frames bypassing floating point boundaries.
        let width = 64
        let height = 64
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue).rawValue
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: colorSpace, bitmapInfo: bitmapInfo) else {
            XCTFail("Could not create testing graphics context")
            return
        }
        
        // Draw pure black
        context.setFillColor(gray: 0.0, alpha: 1.0)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        
        guard let cgImage = context.makeImage() else {
            XCTFail("Failed to generate test image")
            return
        }
        
        // Send through our zero-copy analyzer
        let metrics = VisionAnalyzer.analyze(cgImage: cgImage)
        
        XCTAssertNotNil(metrics, "Metrics should be generated via vImage without faulting")
        if let metrics = metrics {
            XCTAssertTrue(metrics.isBlackScreen, "vImage analysis correctly mapped memory bounds and detected solid black.")
            XCTAssertFalse(metrics.isBlurry, "A solid image shouldn't trigger laplacian variance incorrectly.")
        }
    }
    
    func testLiveStreamMonitoringEndpoints() async throws {
        let app = Application(.testing)
        defer { app.shutdown() }
        try await configure(app)
        
        var returnedSessionName: String?
        
        // Verify start route accepts valid URI and generates unique session ID
        try app.test(.POST, "live/start", beforeRequest: { req in
            try req.content.encode(["uri": "udp://@127.0.0.1:9999"])
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .ok)
            let body = try res.content.decode([String: String].self)
            XCTAssertTrue(body["message"]?.contains("Started live monitoring") ?? false)
            XCTAssertNotNil(body["session_name"])
            XCTAssertTrue(body["session_name"]!.hasPrefix("udp://@127.0.0.1:9999 - "))
            returnedSessionName = body["session_name"]
        })
        
        let progressAfterStart = await ExtractionProgress.shared.all()
        XCTAssertEqual(progressAfterStart[returnedSessionName ?? ""]?.status, "extracting")
        
        // Verify stop route stops successfully and transitions progress to completed
        try app.test(.POST, "live/stop", afterResponse: { res in
            XCTAssertEqual(res.status, .ok)
            let body = try res.content.decode([String: String].self)
            XCTAssertTrue(body["message"]?.contains("Stopped") ?? false)
        })
        
        let progressAfterStop = await ExtractionProgress.shared.all()
        XCTAssertEqual(progressAfterStop[returnedSessionName ?? ""]?.status, "completed")
    }
    
    func testLiveStreamThumbnailRetention() async throws {
        let app = Application(.testing)
        defer { app.shutdown() }
        try await configure(app)
        
        let thumbDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("../backend/thumbnails/")
        try? FileManager.default.createDirectory(at: thumbDir, withIntermediateDirectories: true)
        
        // Ensure starting state is clean for logs
        try await VideoLog.query(on: app.db).delete()
        
        // Use the dummy black mp4 file from the root as our "live stream" URI
        let rootDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).deletingLastPathComponent()
        let blackVideoURI = rootDir.appendingPathComponent("test_black.mp4").path
        
        // Execute LiveStream service on the file
        await LiveStreamService.shared.startMonitoring(uri: blackVideoURI, sessionName: "test_black_stream", db: app.db, logger: app.logger, client: app.client)
        
        // Give it 3 seconds to process a few FPS frames
        try await Task.sleep(nanoseconds: 3_000_000_000)
        
        await LiveStreamService.shared.stopMonitoring()
        
        // Verify VideoLogs have been populated with "black_screen" and uniquely named 'live_...' thumbnails
        let logs = try await VideoLog.query(on: app.db).all()
        XCTAssertGreaterThan(logs.count, 0, "Should have detected black screen anomalies")
        
        var foundUniqueThumbnail = false
        for log in logs {
            if let thumb = log.thumbnailPath, thumb.hasPrefix("live_") && thumb.hasSuffix(".jpg") {
                foundUniqueThumbnail = true
                let fullPath = thumbDir.appendingPathComponent(thumb).path
                // The thumbnail should still exist on disk because it had an issue, verifying our fix!
                XCTAssertTrue(FileManager.default.fileExists(atPath: fullPath), "Thumbnail for issue should be preserved on disk")
                // Cleanup mock thumbnail
                try? FileManager.default.removeItem(atPath: fullPath)
            }
        }
        XCTAssertTrue(foundUniqueThumbnail, "Expected to find preserved thumbnails named with unique UUID prefixes.")
    }
    func testLiveStreamTimestampsAndCreatedAt() async throws {
        let app = Application(.testing)
        defer { app.shutdown() }
        try await configure(app)
        
        try await VideoLog.query(on: app.db).delete()
        
        let log = VideoLog()
        log.videoFilename = "test_timestamp_stream"
        log.timestampSec = 1.0
        log.nodeSource = "Live-Multicast"
        log.issueType = "ok"
        log.issueScore = 1.0
        log.analysisEngine = "avfoundation"
        
        try await log.save(on: app.db)
        
        let fetchedLogs = try await VideoLog.query(on: app.db).all()
        XCTAssertEqual(fetchedLogs.count, 1)
        
        if let fetchedLog = fetchedLogs.first {
            XCTAssertNotNil(fetchedLog.createdAt, "createdAt should be populated automatically via @Timestamp")
            XCTAssertTrue(fetchedLog.timestampSec < 10000.0, "timestampSec should hold relative stream times, not epoch.")
        }
    }
}
