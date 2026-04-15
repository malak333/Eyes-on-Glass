import Foundation
import CoreImage

@MainActor
func testFiles() async {
    let files = try! FileManager.default.contentsOfDirectory(atPath: ".")
    let tsFiles = files.filter { $0.hasSuffix(".ts") || $0.hasSuffix(".mp4") }
    
    // We only take the first frame as a fast proxy, or ideal would be to use AVAssetImageGenerator to get an I-frame, but that takes code.
}
