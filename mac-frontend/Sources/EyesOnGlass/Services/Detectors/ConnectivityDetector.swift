import Foundation
import CoreVideo

struct ConnectivityDetector: AnomalyDetector {
    private var pendingCCErrorsCount: Int = 0

    mutating func incrementPendingCCErrors() {
        pendingCCErrorsCount += 1
    }

    mutating func analyze(
        pixelBuffer: CVPixelBuffer,
        encodedFrame: Data?,
        cvResults: ValidationMetrics?,
        now: TimeInterval,
        frameCount: Int,
        thumbnailsDir: URL,
        visualRingBuffer: [Data]
    ) async -> [Anomaly] {
        var anomalies: [Anomaly] = []

        if pendingCCErrorsCount > 0 {
            let errorText = "\(pendingCCErrorsCount) CC Error\(pendingCCErrorsCount > 1 ? "s" : "")"
            anomalies.append(Anomaly(type: "cc_error", score: 1.0, engine: "ingestor", summary: "\(errorText) Detected", boundingBoxes: nil))
            pendingCCErrorsCount = 0
        }

        return anomalies
    }
}
