import Foundation
let p = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("../backend/thumbnails/")
let files = try? FileManager.default.contentsOfDirectory(atPath: p.path)
let sortedFrames = files?.filter { $0.hasPrefix("KGO-VOD-Encoder.ts_frame_") && $0.hasSuffix(".jpg") }.sorted()
print("KGO count: \(sortedFrames?.count ?? -1)")
