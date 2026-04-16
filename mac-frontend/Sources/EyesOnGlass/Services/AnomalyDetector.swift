import Foundation
import CoreVideo

struct Anomaly: Sendable {
    let type: String
    let score: Double
    let engine: String
    let summary: String?
    let boundingBoxes: String?
}

protocol AnomalyDetector: Sendable {
    mutating func analyze(
        pixelBuffer: CVPixelBuffer,
        encodedFrame: Data?,
        cvResults: ValidationMetrics?,
        now: TimeInterval,
        frameCount: Int,
        thumbnailsDir: URL,
        visualRingBuffer: [Data]
    ) async -> [Anomaly]
}
