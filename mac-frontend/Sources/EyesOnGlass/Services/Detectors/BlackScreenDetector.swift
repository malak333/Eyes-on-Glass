import Foundation
import CoreVideo
import CoreImage

actor BlackScreenDetector: AnomalyDetector {
    private var isCurrentlyBlackScreen: Bool = false
    private var blackScreenStartTime: TimeInterval? = nil
    private var preBlackScreenFramePath: String? = nil
    private var representativeBlackFramePath: String? = nil
    private var lastFrameData: Data?

    func reset() async {
        isCurrentlyBlackScreen = false
        blackScreenStartTime = nil
        preBlackScreenFramePath = nil
        representativeBlackFramePath = nil
        lastFrameData = nil
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

        guard let cv = cvResults else { return [] }

        if cv.isBlackScreen {
            if !isCurrentlyBlackScreen {
                isCurrentlyBlackScreen = true
                blackScreenStartTime = nowTime

                if let data = lastFrameData {
                    let url = thumbnailsDir.appendingPathComponent("live_prior_\(UUID().uuidString).heic")
                    try? data.write(to: url)
                    preBlackScreenFramePath = url.path
                }

                if let data = heicData {
                    let url = thumbnailsDir.appendingPathComponent("live_event_\(UUID().uuidString).heic")
                    try? data.write(to: url)
                    representativeBlackFramePath = url.path
                }
            } else if let startTime = blackScreenStartTime, nowTime - startTime >= 7.0 {
                issues.append(DetectedIssue(
                    type: "black_screen",
                    score: 1.0,
                    engine: "opencv",
                    summary: "Timeout exceeded without recovery",
                    thumbnailPath: representativeBlackFramePath.map { URL(fileURLWithPath: $0).lastPathComponent }
                ))

                isCurrentlyBlackScreen = false
                blackScreenStartTime = nil
                preBlackScreenFramePath = nil
                representativeBlackFramePath = nil
            }
        } else {
            if isCurrentlyBlackScreen {
                let restorationFramePath: String?
                if let data = heicData {
                    let url = thumbnailsDir.appendingPathComponent("live_event_\(UUID().uuidString).heic")
                    try? data.write(to: url)
                    restorationFramePath = url.path
                } else {
                    restorationFramePath = nil
                }

                if let prePath = preBlackScreenFramePath,
                   let repPath = representativeBlackFramePath,
                   let endPath = restorationFramePath {

                    let tier = await MainActor.run { NativeVLMClient.shared.selectedTier }

                    Task(priority: .utility) { [weak reporter] in
                        let (isFailure, reason) = await NativeVLMClient.shared.analyzeBlackScreenTransition(preFrame: prePath, blackFrame: repPath, endFrame: endPath, tier: tier)
                        if isFailure {
                            reporter?.enqueueVideoLog(
                                type: "black_screen",
                                score: 1.0,
                                engine: tier.displayName,
                                summary: reason,
                                boundingBoxes: nil,
                                thumbnailPath: URL(fileURLWithPath: repPath).lastPathComponent,
                                nodeSource: nil,
                                nodeBackbone: nil,
                                nodeDest: nil
                            )
                        }
                    }
                }

                isCurrentlyBlackScreen = false
                blackScreenStartTime = nil
                preBlackScreenFramePath = nil
                representativeBlackFramePath = nil
            }
        }

        lastFrameData = heicData
        return issues
    }
}
