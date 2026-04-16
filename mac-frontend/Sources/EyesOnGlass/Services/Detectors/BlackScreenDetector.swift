import Foundation
import CoreVideo
import CoreImage

struct BlackScreenDetector: AnomalyDetector {
    private var isCurrentlyBlackScreen: Bool = false
    private var blackScreenStartTime: TimeInterval? = nil
    private var preBlackScreenFramePath: String? = nil
    private var representativeBlackFramePath: String? = nil

    private let streamController: StreamController?

    init(streamController: StreamController?) {
        self.streamController = streamController
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

        guard let cv = cvResults else { return [] }

        if cv.isBlackScreen {
            if !isCurrentlyBlackScreen {
                isCurrentlyBlackScreen = true
                blackScreenStartTime = now
                preBlackScreenFramePath = getPreviousFrameHEIC(visualRingBuffer: visualRingBuffer, thumbnailsDir: thumbnailsDir)
                representativeBlackFramePath = saveCurrentFrameHEIC(data: encodedFrame, thumbnailsDir: thumbnailsDir)
            } else if let startTime = blackScreenStartTime, now - startTime >= 7.0 {
                anomalies.append(Anomaly(type: "black_screen", score: 1.0, engine: "opencv", summary: "Timeout exceeded without recovery", boundingBoxes: nil))
                isCurrentlyBlackScreen = false
                blackScreenStartTime = nil
                preBlackScreenFramePath = nil
                representativeBlackFramePath = nil
            }
        } else {
            if isCurrentlyBlackScreen {
                let restorationFramePath = saveCurrentFrameHEIC(data: encodedFrame, thumbnailsDir: thumbnailsDir)

                if let prePath = preBlackScreenFramePath, let repPath = representativeBlackFramePath, let endPath = restorationFramePath {
                    let tier = await MainActor.run { NativeVLMClient.shared.selectedTier }
                    let sessionBackup = await MainActor.run { streamController?.activeSessionName ?? "unknown" }

                    Task(priority: .utility) {
                        let (isFailure, reason) = await NativeVLMClient.shared.analyzeBlackScreenTransition(preFrame: prePath, blackFrame: repPath, endFrame: endPath, tier: tier)
                        if isFailure {
                            await MainActor.run {
                                streamController?.insertVideoLog(
                                    videoFilename: sessionBackup,
                                    timestampSec: Double(frameCount),
                                    nodeSource: "Live-Multicast",
                                    nodeBackbone: "East-Backbone-Live",
                                    nodeDest: "Distribution-Node",
                                    issueType: "black_screen",
                                    issueScore: 1.0,
                                    analysisEngine: tier.displayName,
                                    thumbnailPath: URL(fileURLWithPath: repPath).lastPathComponent,
                                    issueSummary: reason
                                )
                            }
                        }
                    }
                }

                isCurrentlyBlackScreen = false
                blackScreenStartTime = nil
                preBlackScreenFramePath = nil
                representativeBlackFramePath = nil
            }
        }

        return anomalies
    }

    private func getPreviousFrameHEIC(visualRingBuffer: [Data], thumbnailsDir: URL) -> String? {
        guard let data = visualRingBuffer.first else { return nil }
        let url = thumbnailsDir.appendingPathComponent("live_prior_\(UUID().uuidString).heic")
        try? data.write(to: url)
        return url.path
    }

    private func saveCurrentFrameHEIC(data: Data?, thumbnailsDir: URL) -> String? {
        guard let data = data else { return nil }
        let url = thumbnailsDir.appendingPathComponent("live_event_\(UUID().uuidString).heic")
        try? data.write(to: url)
        return url.path
    }
}
