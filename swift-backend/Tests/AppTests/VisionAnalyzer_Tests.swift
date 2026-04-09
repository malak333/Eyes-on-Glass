@testable import App
import XCTVapor
import CoreImage
import Accelerate

final class VisionAnalyzer_Tests: XCTestCase {
    
    /// Generates a test CGImage with specific synthetic data for basic validation
    private func createTestCGImage(width: Int, height: Int, pattern: (Int, Int) -> UInt8) -> CGImage? {
        var data = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                data[y * width + x] = pattern(x, y)
            }
        }
        
        let colorSpace = CGColorSpaceCreateDeviceGray()
        let context = CGContext(
            data: &data,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        )
        return context?.makeImage()
    }
    
    func testBlackScreenDetection() throws {
        // Create an entirely black image
        guard let cgImage = createTestCGImage(width: 32, height: 32, pattern: { _, _ in 0 }) else {
            XCTFail("Failed to create test image")
            return
        }
        
        guard let metrics = VisionAnalyzer.analyze(cgImage: cgImage) else {
            XCTFail("VisionAnalyzer failed to process image")
            return
        }
        
        XCTAssertTrue(metrics.isBlackScreen, "An entirely black image should trigger isBlackScreen.")
        XCTAssertFalse(metrics.isBlurry, "A black screen should not be noisy enough to be blurry.")
    }
    
    func testNormalImageDoesNotTriggerFalsePositives() throws {
        // Create a pseudo-random looking pattern that is not blocky and has high variance
        guard let cgImage = createTestCGImage(width: 64, height: 64, pattern: { x, y in
            return UInt8((x * y) % 255)
        }) else {
            XCTFail("Failed to create test image")
            return
        }
        
        guard let metrics = VisionAnalyzer.analyze(cgImage: cgImage) else {
            XCTFail("VisionAnalyzer failed to process image")
            return
        }
        
        XCTAssertFalse(metrics.isBlackScreen, "A varied image should not be a black screen.")
        XCTAssertFalse(metrics.isBars, "A varied image should not trigger bars.")
        
        // Blockiness should be small since there's no synthetic block grid
        XCTAssertTrue(metrics.blockiness < 30.0, "Blockiness should be within normal ranges.")
    }
    
    func testMinimumSizeConstraints() throws {
        // Create an image smaller than 16x16, the analyzer should return basic defaults
        guard let cgImage = createTestCGImage(width: 8, height: 8, pattern: { _, _ in 128 }) else {
            XCTFail("Failed to create test image")
            return
        }
        
        guard let metrics = VisionAnalyzer.analyze(cgImage: cgImage) else {
            XCTFail("VisionAnalyzer failed to process image")
            return
        }
        
        XCTAssertEqual(metrics.blockiness, 1.0, "Too small images should return default blockiness 1.0")
        XCTAssertFalse(metrics.isBars)
        XCTAssertFalse(metrics.isSnowflakes)
        XCTAssertFalse(metrics.isBlurry)
        XCTAssertFalse(metrics.hasTopArtifact)
    }
}
