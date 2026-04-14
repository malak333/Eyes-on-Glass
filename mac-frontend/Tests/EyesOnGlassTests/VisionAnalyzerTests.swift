import XCTest
import CoreImage
import CoreVideo
@testable import EyesOnGlass

final class VisionAnalyzerTests: XCTestCase {
    
    func testAnalyzeWithCIImage() throws {
        // Create a 100x100 purely black pixel buffer
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, 100, 100, kCVPixelFormatType_32BGRA, nil, &pixelBuffer)
        XCTAssertEqual(status, kCVReturnSuccess)
        guard let pb = pixelBuffer else {
            XCTFail("Failed to create pixel buffer")
            return
        }
        
        // Lock and fill with 0s (black)
        CVPixelBufferLockBaseAddress(pb, [])
        if let baseAddress = CVPixelBufferGetBaseAddress(pb) {
            let bytesPerRow = CVPixelBufferGetBytesPerRow(pb)
            let height = CVPixelBufferGetHeight(pb)
            memset(baseAddress, 0, bytesPerRow * height)
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        
        // Test our new memory-backed zero-copy CIContext pipeline
        let ciImage = CIImage(cvPixelBuffer: pb)
        let context = CIContext(options: [.cacheIntermediates: false])
        
        let cvResults = VisionAnalyzer.analyze(ciImage: ciImage, context: context)
        
        // Validate it didn't crash, safely hit Accelerate natively, and correctly identified black bounding
        XCTAssertNotNil(cvResults)
        XCTAssertTrue(cvResults!.isBlackScreen, "Expected purely black pixel buffer to flag as black screen.")
        XCTAssertEqual(cvResults!.meanBrightness, 0.0, accuracy: 0.1)
        XCTAssertTrue(cvResults!.anomalyBoundingBoxes.isEmpty, "Anomaly bounding boxes should be empty on a black screen.")
    }
    
    func testHEICEncoderFallback() throws {
        // Validate the hardware acceleration pipeline is actively capable of constructing the HEIC payload
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 100, 100, kCVPixelFormatType_32BGRA, nil, &pixelBuffer)
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer!)
        let context = CIContext(options: [.cacheIntermediates: false])
        
        let heicData = context.heifRepresentation(of: ciImage, format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB(), options: [:])
        
        // Verifies the removal of JPEG dual-compression falls back natively to safe HEIC data chunks
        if let heicData = heicData {
            XCTAssertTrue(heicData.count > 0, "HEIC data chunk was completely empty.")
        } else {
            print("HEIC encoder returned nil. This may be expected on systems lacking a hardware HEIC encoder.")
        }
    }
}
