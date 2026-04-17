import Foundation
import CoreVideo
import CoreImage

actor AudioAnomalyDetector: AnomalyDetector {
    private var audioLossStartTime: TimeInterval? = nil
    private var wasAudioHealthy: Bool? = nil

    func reset() async {
        audioLossStartTime = nil
        wasAudioHealthy = nil
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
        let nowTime = CFAbsoluteTimeGetCurrent()
        let isAudioHealthy = (audioHealth == .healthy)

        if isAudioHealthy {
            audioLossStartTime = nil
            if let previous = wasAudioHealthy, !previous {
                issues.append(DetectedIssue(
                    type: "audio_restored",
                    score: 1.0,
                    engine: "ingestor"
                ))
            }
            wasAudioHealthy = true
        } else {
            if audioLossStartTime == nil {
                audioLossStartTime = nowTime
            }

            let timeUnhealthy = nowTime - (audioLossStartTime ?? nowTime)

            if timeUnhealthy >= 2.0 {
                if let previous = wasAudioHealthy {
                    if previous {
                        issues.append(DetectedIssue(
                            type: "audio_lost",
                            score: 1.0,
                            engine: "ingestor"
                        ))
                    }
                }
                wasAudioHealthy = false
            }
        }

        return issues
    }
}
