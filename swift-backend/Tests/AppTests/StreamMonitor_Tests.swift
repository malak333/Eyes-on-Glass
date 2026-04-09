import XCTest
import CoreVideo
@testable import App

final class StreamMonitor_Tests: XCTestCase {
    
    func testStrictPTSSynchronization() async throws {
        let monitor = StreamMonitor()
        
        let cvPixelBufferAttrs = [kCVPixelBufferCGImageCompatibilityKey: kCFBooleanTrue,
                                  kCVPixelBufferCGBitmapContextCompatibilityKey: kCFBooleanTrue] as CFDictionary
        var pixelBufferOut: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 100, 100, kCVPixelFormatType_32BGRA, cvPixelBufferAttrs, &pixelBufferOut)
        
        guard let frame = pixelBufferOut else {
            XCTFail("Failed to create mock pixel buffer")
            return
        }
        
        let videoHealth = VideoHealth(frame: frame)
        let audioHealth = AudioHealth.healthy
        let pts: Int64 = 90000
        
        let expectation = XCTestExpectation(description: "Wait for synced CVPixelBuffer callback")
        
        await monitor.setOnSynced { buffer in
            expectation.fulfill()
        }
        
        // Report audio arrival first
        await monitor.report(pts: pts, video: nil, audio: audioHealth)
        
        // Report video arrival second to complete the sync
        await monitor.report(pts: pts, video: videoHealth, audio: nil)
        
        await fulfillment(of: [expectation], timeout: 1.0)
    }
    
    func testWindowedPTSSynchronization() async throws {
        let monitor = StreamMonitor()
        
        let cvPixelBufferAttrs = [kCVPixelBufferCGImageCompatibilityKey: kCFBooleanTrue,
                                  kCVPixelBufferCGBitmapContextCompatibilityKey: kCFBooleanTrue] as CFDictionary
        var pixelBufferOut: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 100, 100, kCVPixelFormatType_32BGRA, cvPixelBufferAttrs, &pixelBufferOut)
        
        let frame = pixelBufferOut!
        let videoHealth = VideoHealth(frame: frame)
        let audioHealth = AudioHealth.healthy
        
        // Offset PTS slightly to simulate TS demux variation
        let videoPTS: Int64 = 90000
        let audioPTS: Int64 = 93003 // ~33ms off
        
        let expectation = XCTestExpectation(description: "Wait for windowed CVPixelBuffer callback")
        
        await monitor.setOnSynced { buffer in
            expectation.fulfill()
        }
        
        await monitor.report(pts: audioPTS, video: nil, audio: audioHealth)
        await monitor.report(pts: videoPTS, video: videoHealth, audio: nil)
        
        await fulfillment(of: [expectation], timeout: 1.0)
    }
    
    func testStalePruningAndTimeout() async throws {
        let monitor = StreamMonitor()
        
        let cvPixelBufferAttrs = [kCVPixelBufferCGImageCompatibilityKey: kCFBooleanTrue,
                                  kCVPixelBufferCGBitmapContextCompatibilityKey: kCFBooleanTrue] as CFDictionary
        var pixelBufferOut: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 100, 100, kCVPixelFormatType_32BGRA, cvPixelBufferAttrs, &pixelBufferOut)
        
        let frame = pixelBufferOut!
        
        let videoHealth = VideoHealth(frame: frame)
        let staleVideoPTS: Int64 = 100
        let freshVideoPTS: Int64 = 100 + 45_000 + 10 // Beyond stale threshold
        let expectation1 = XCTestExpectation(description: "Wait for stale CVPixelBuffer callback with timeout fallback")
        let expectation2 = XCTestExpectation(description: "Wait for fresh CVPixelBuffer callback with timeout fallback")
        
        var callCount = 0
        await monitor.setOnSynced { buffer in
            callCount += 1
            if callCount == 1 { expectation1.fulfill() }
            if callCount == 2 { expectation2.fulfill() }
        }
        
        // Provide video without audio
        await monitor.report(pts: staleVideoPTS, video: videoHealth, audio: nil)
        
        // Report a new advanced PTS, pushing the stale threshold
        await monitor.report(pts: freshVideoPTS, video: videoHealth, audio: nil)
        
        // Now trigger the final process iteration by submitting a far-future mock packet
        await monitor.report(pts: freshVideoPTS + 45_000 + 10, video: nil, audio: .healthy)
        
        await fulfillment(of: [expectation1, expectation2], timeout: 1.0)
    }
    
    func testStrict1FPSRateLimiting() async throws {
        // Enforces rule 1: Automated testing for the StreamMonitor 1-FPS governor
        let monitor = StreamMonitor()
        
        let cvPixelBufferAttrs = [kCVPixelBufferCGImageCompatibilityKey: kCFBooleanTrue,
                                  kCVPixelBufferCGBitmapContextCompatibilityKey: kCFBooleanTrue] as CFDictionary
        var pixelBufferOut: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 100, 100, kCVPixelFormatType_32BGRA, cvPixelBufferAttrs, &pixelBufferOut)
        
        guard let frame = pixelBufferOut else {
            XCTFail("Failed to create mock pixel buffer")
            return
        }
        
        var callbackCount = 0
        await monitor.setOnSynced { _ in
            callbackCount += 1
        }
        
        // Simulating exactly 30 frames arriving within a 1-second window (90,000 / 30 = 3000 ticks per frame)
        // Since we enforced 1-FPS rate limiting via `(pts - lastProcessedPTS >= 90000)`, it should only fire ONCE!
        let basePTS: Int64 = 100_000
        for i in 0..<30 {
            let pts = basePTS + Int64(i * 3000)
            await monitor.report(pts: pts, video: VideoHealth(frame: frame), audio: .healthy)
        }
        
        // Send a 31st frame exactly 1 second (90000 ticks) after the first one to trigger the second callback
        await monitor.report(pts: basePTS + 90000, video: VideoHealth(frame: frame), audio: .healthy)
        
        // Verify only 2 frames made it out (the first one, and the one exactly 1 second later)
        XCTAssertEqual(callbackCount, 2, "StreamMonitor must aggressively cull frames and strictly output exactly 1 FPS (1 callback per 90,000 PTS ticks)")
    }
}
