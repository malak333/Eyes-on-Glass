import Foundation
import CoreVideo
import CoreImage

/// A protocol for reporting video logs from detectors.
protocol VideoLogReporter: AnyObject, Sendable {
    func enqueueVideoLog(
        type: String,
        score: Double,
        engine: String,
        summary: String?,
        boundingBoxes: String?,
        thumbnailPath: String?,
        nodeSource: String?,
        nodeBackbone: String?,
        nodeDest: String?
    )
}

/// A protocol defining the standard interface for an anomaly detector.
protocol AnomalyDetector: Actor {
    /// Resets the detector state for a new monitoring session.
    func reset() async

    /// Processes a single frame and its associated metadata to detect anomalies.
    func detectAnomalies(
        pixelBuffer: CVPixelBuffer,
        ciImage: CIImage,
        cvResults: ValidationMetrics?,
        audioHealth: AudioHealth,
        networkIAT: Double,
        sessionName: String,
        frameIndex: Int,
        thumbnailsDir: URL,
        reporter: VideoLogReporter?,
        heicData: Data?
    ) async -> [DetectedIssue]
}

/// Represents a detected anomaly issue.
struct DetectedIssue: Sendable {
    let type: String
    let score: Double
    let engine: String
    let summary: String?
    let boundingBoxes: String?
    let thumbnailPath: String?
    let customNodeSource: String?
    let customNodeBackbone: String?
    let customNodeDest: String?

    init(
        type: String,
        score: Double,
        engine: String,
        summary: String? = nil,
        boundingBoxes: String? = nil,
        thumbnailPath: String? = nil,
        customNodeSource: String? = nil,
        customNodeBackbone: String? = nil,
        customNodeDest: String? = nil
    ) {
        self.type = type
        self.score = score
        self.engine = engine
        self.summary = summary
        self.boundingBoxes = boundingBoxes
        self.thumbnailPath = thumbnailPath
        self.customNodeSource = customNodeSource
        self.customNodeBackbone = customNodeBackbone
        self.customNodeDest = customNodeDest
    }
}
