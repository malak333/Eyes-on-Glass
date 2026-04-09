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
}

