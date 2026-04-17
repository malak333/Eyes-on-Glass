import Foundation
import CoreVideo
import CoreImage

actor ConnectivityDetector: AnomalyDetector {
    private var pendingCCErrorsCount: Int = 0

    func reset() async {
        pendingCCErrorsCount = 0
    }

    func incrementCCErrors() {
        pendingCCErrorsCount += 1
    }

    func getAndResetCCErrors() -> Int {
        let count = pendingCCErrorsCount
        pendingCCErrorsCount = 0
        return count
    }

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
    ) async -> [DetectedIssue] {
        var issues: [DetectedIssue] = []

        let currentCCErrors = getAndResetCCErrors()

        if currentCCErrors > 0 {
            let errorText = "\(currentCCErrors) CC Error\(currentCCErrors > 1 ? "s" : "")"
            issues.append(DetectedIssue(
                type: "cc_error",
                score: 1.0,
                engine: "ingestor",
                summary: "\(errorText) Detected"
            ))
        }

        if networkIAT > 40.0 {
            issues.append(DetectedIssue(
                type: "high_iat",
                score: 1.0,
                engine: "ingestor",
                summary: String(format: "IAT spiked to %.1f ms", networkIAT)
            ))
        }

        return issues
    }
}
