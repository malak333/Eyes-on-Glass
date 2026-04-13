import Foundation
import CoreVideo
import CoreImage
import Accelerate

@main
struct TestVision {
    static func main() {
        print("Testing VisionAnalyzer on CIRCLE video frames...")

        // Assuming we have frames in ./thumbnails/
        let urlStr = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("thumbnails")
        guard let files = try? FileManager.default.contentsOfDirectory(at: urlStr, includingPropertiesForKeys: nil) else {
            print("Could not find thumbnails")
            return
        }

        for file in files {
            if true {
                if let metrics = VisionAnalyzer.analyze(imagePath: file.path) {
                    let macroConfidence = min(1.0, max(0.0, (metrics.blockiness - 1.25) / 0.5))
                    print("File: \(file.lastPathComponent)")
                    print("  blockiness: \(metrics.blockiness)")
                    print("  variance: \(metrics.laplacianVariance)")
                    print("  confidence: \(macroConfidence)")
                }
            }
        }
    }
}
