import Foundation
import CoreVideo
import CoreImage

actor MacroblockingDetector: AnomalyDetector {
    private var lastMacroblockingIndex: Int = -2
    private var isCurrentMBSeriesVerified: Bool = false
    private var consecutiveMBCount: Int = 0
    private var currentMBVerifiedEngine: String = "opencv"
    private var peakMacroblockingScore: Double = 0.0
    private var peakMacroblockingFramePath: String?
    private var startOfIncidentPath: String?

    private var lastFrameData: Data?

    func reset() async {
        lastMacroblockingIndex = -2
        isCurrentMBSeriesVerified = false
        consecutiveMBCount = 0
        currentMBVerifiedEngine = "opencv"
        peakMacroblockingScore = 0.0
        peakMacroblockingFramePath = nil
        startOfIncidentPath = nil
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

        guard let cv = cvResults, !cv.isBlackScreen else {
            // Handle incident end (Stage B) if series was verified
            if isCurrentMBSeriesVerified {
                await handleStageB(frameIndex: frameIndex, thumbnailsDir: thumbnailsDir, currentFrameHEIC: heicData, reporter: reporter)
            }
            lastFrameData = heicData
            return []
        }

        let macroConfidence = cv.macroConfidence
        let definitivelyMacroblocked = cv.isDefinitivelyMacroblocked

        var savedThumbPath: String?
        if definitivelyMacroblocked {
            if let data = heicData {
                let url = thumbnailsDir.appendingPathComponent("live_\(UUID().uuidString).heic")
                try? data.write(to: url)
                savedThumbPath = url.path
            }

            var boundingBoxesJSON: String?
            if !cv.anomalyBoundingBoxes.isEmpty {
                let boxesArray = cv.anomalyBoundingBoxes.map { [$0.origin.x, $0.origin.y, $0.size.width, $0.size.height] }
                if let data = try? JSONSerialization.data(withJSONObject: boxesArray),
                   let jsonString = String(data: data, encoding: .utf8) {
                    boundingBoxesJSON = jsonString
                }
            }

            let seriesGap = frameIndex - lastMacroblockingIndex
            let wasGap = seriesGap > 1
            lastMacroblockingIndex = frameIndex

            if wasGap {
                isCurrentMBSeriesVerified = false
                consecutiveMBCount = 1
                startOfIncidentPath = savedThumbPath
                peakMacroblockingScore = Double(macroConfidence)
                peakMacroblockingFramePath = savedThumbPath
            } else {
                consecutiveMBCount += 1
                if let currentPath = savedThumbPath, Double(macroConfidence) > peakMacroblockingScore {
                    peakMacroblockingScore = Double(macroConfidence)
                    peakMacroblockingFramePath = currentPath
                }
            }

            if isCurrentMBSeriesVerified {
                issues.append(DetectedIssue(
                    type: "macroblocking",
                    score: Double(macroConfidence),
                    engine: currentMBVerifiedEngine,
                    boundingBoxes: boundingBoxesJSON,
                    thumbnailPath: savedThumbPath.map { URL(fileURLWithPath: $0).lastPathComponent }
                ))
            } else if consecutiveMBCount == 2 {
                // Trigger VLM Stage A
                let priorPath: String?
                if let data = lastFrameData {
                    let url = thumbnailsDir.appendingPathComponent("live_prior_\(UUID().uuidString).heic")
                    try? data.write(to: url)
                    priorPath = url.path
                } else {
                    priorPath = nil
                }

                if let peakPath = peakMacroblockingFramePath, let lastGood = priorPath {
                    let tier = await MainActor.run { NativeVLMClient.shared.selectedTier }
                    let isVlmReady = await MainActor.run {
                        if case .ready = NativeVLMClient.shared.state { return true }
                        return false
                    }

                    if isVlmReady {
                        Task(priority: .utility) { [weak self, weak reporter] in
                            let isVerified = await NativeVLMClient.shared.analyzeStageA(lastGood: lastGood, bad: peakPath, tier: tier)
                            if isVerified {
                                await self?.markVerified(engine: tier.displayName)
                                reporter?.enqueueVideoLog(
                                    type: "macroblocking",
                                    score: await self?.getPeakScore() ?? 1.0,
                                    engine: tier.displayName,
                                    summary: nil,
                                    boundingBoxes: boundingBoxesJSON,
                                    thumbnailPath: URL(fileURLWithPath: peakPath).lastPathComponent,
                                    nodeSource: nil,
                                    nodeBackbone: nil,
                                    nodeDest: nil
                                )
                            } else {
                                await self?.resetIncident()
                            }
                        }
                    } else {
                        // Offline fallback
                        isCurrentMBSeriesVerified = true
                        currentMBVerifiedEngine = "offline"
                        issues.append(DetectedIssue(
                            type: "macroblocking",
                            score: peakMacroblockingScore,
                            engine: "offline",
                            boundingBoxes: boundingBoxesJSON,
                            thumbnailPath: savedThumbPath.map { URL(fileURLWithPath: $0).lastPathComponent }
                        ))
                    }
                }
            }
        } else {
            // Check if an incident just cleared (Stage B)
            if isCurrentMBSeriesVerified {
                await handleStageB(frameIndex: frameIndex, thumbnailsDir: thumbnailsDir, currentFrameHEIC: heicData, reporter: reporter)
            }
        }

        if cv.hasTopArtifact {
            issues.append(DetectedIssue(type: "top_artifact", score: 1.0, engine: "opencv"))
        }
        if cv.isBars {
            issues.append(DetectedIssue(type: "bars_and_tone", score: 1.0, engine: "opencv"))
        }
        if cv.isSnowflakes {
            issues.append(DetectedIssue(type: "snowflakes", score: 1.0, engine: "opencv"))
        }

        lastFrameData = heicData
        return issues
    }

    private func handleStageB(frameIndex: Int, thumbnailsDir: URL, currentFrameHEIC: Data?, reporter: VideoLogReporter?) async {
        guard let start = startOfIncidentPath, let peak = peakMacroblockingFramePath else { return }

        let endPath: String?
        if let data = currentFrameHEIC {
            let url = thumbnailsDir.appendingPathComponent("live_event_\(UUID().uuidString).heic")
            try? data.write(to: url)
            endPath = url.path
        } else {
            endPath = nil
        }

        let tier = await MainActor.run { NativeVLMClient.shared.selectedTier }

        if let end = endPath {
            Task(priority: .utility) { [weak reporter] in
                if let summary = await NativeVLMClient.shared.analyzeStageB(start: start, peak: peak, end: end, tier: tier) {
                    reporter?.enqueueVideoLog(
                        type: "macroblocking_incident_summary",
                        score: 1.0,
                        engine: tier.displayName,
                        summary: summary,
                        boundingBoxes: nil,
                        thumbnailPath: URL(fileURLWithPath: peak).lastPathComponent,
                        nodeSource: "VLM-Forensic",
                        nodeBackbone: "East-Backbone-Live",
                        nodeDest: "Incident Report"
                    )
                }
            }
        }

        isCurrentMBSeriesVerified = false
        startOfIncidentPath = nil
        peakMacroblockingFramePath = nil
    }

    private func markVerified(engine: String) {
        isCurrentMBSeriesVerified = true
        currentMBVerifiedEngine = engine
    }

    private func resetIncident() {
        consecutiveMBCount = 0
        startOfIncidentPath = nil
        peakMacroblockingFramePath = nil
    }

    private func getPeakScore() -> Double {
        return peakMacroblockingScore
    }
}
