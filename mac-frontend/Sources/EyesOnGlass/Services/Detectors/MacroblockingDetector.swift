import Foundation
import CoreVideo

struct MacroblockingDetector: AnomalyDetector {
    private var lastMacroblockingIndex: Int = -2
    private var isCurrentMBSeriesVerified: Bool = false
    private var consecutiveMBCount: Int = 0
    private var currentMBVerifiedEngine: String = "opencv"
    private var peakMacroblockingScore: Double = 0.0
    private var peakMacroblockingFramePath: String?
    private var startOfIncidentPath: String?

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

        guard let cv = cvResults, !cv.isBlackScreen else { return [] }

        if cv.isBars { anomalies.append(Anomaly(type: "bars_and_tone", score: 1.0, engine: "opencv", summary: nil, boundingBoxes: nil)) }
        if cv.isSnowflakes { anomalies.append(Anomaly(type: "snowflakes", score: 1.0, engine: "opencv", summary: nil, boundingBoxes: nil)) }
        if cv.hasTopArtifact { anomalies.append(Anomaly(type: "top_artifact", score: 1.0, engine: "opencv", summary: nil, boundingBoxes: nil)) }

        let macroConfidence = cv.macroConfidence
        let definitivelyMacroblocked = cv.isDefinitivelyMacroblocked

        var boundingBoxesJSON: String? = nil
        if definitivelyMacroblocked {
            if !cv.anomalyBoundingBoxes.isEmpty {
                let boxesArray = cv.anomalyBoundingBoxes.map { [$0.origin.x, $0.origin.y, $0.size.width, $0.size.height] }
                if let data = try? JSONSerialization.data(withJSONObject: boxesArray),
                   let jsonString = String(data: data, encoding: .utf8) {
                    boundingBoxesJSON = jsonString
                }
            }

            let seriesGap = frameCount - lastMacroblockingIndex
            let wasGap = seriesGap > 1
            lastMacroblockingIndex = frameCount

            let currentPath = saveCurrentFrameHEIC(data: encodedFrame, thumbnailsDir: thumbnailsDir)

            if wasGap {
                isCurrentMBSeriesVerified = false
                consecutiveMBCount = 1
                startOfIncidentPath = currentPath
                peakMacroblockingScore = Double(macroConfidence)
                peakMacroblockingFramePath = currentPath
            } else {
                consecutiveMBCount += 1
                if let path = currentPath, Double(macroConfidence) > peakMacroblockingScore {
                    peakMacroblockingScore = Double(macroConfidence)
                    peakMacroblockingFramePath = path
                }
            }

            if isCurrentMBSeriesVerified {
                anomalies.append(Anomaly(type: "macroblocking", score: Double(macroConfidence), engine: currentMBVerifiedEngine, summary: nil, boundingBoxes: boundingBoxesJSON))
            } else if consecutiveMBCount == 2 {
                let tier = await MainActor.run { NativeVLMClient.shared.selectedTier }
                let isVlmReady = await MainActor.run {
                    if case .ready = NativeVLMClient.shared.state { return true }
                    return false
                }

                if isVlmReady {
                    if let priorPath = getPreviousFrameHEIC(visualRingBuffer: visualRingBuffer, thumbnailsDir: thumbnailsDir), let peakPath = peakMacroblockingFramePath {
                        let isVerified = await NativeVLMClient.shared.analyzeStageA(lastGood: priorPath, bad: peakPath, tier: tier)
                        if isVerified {
                            isCurrentMBSeriesVerified = true
                            currentMBVerifiedEngine = tier.displayName
                            anomalies.append(Anomaly(type: "macroblocking", score: peakMacroblockingScore, engine: tier.displayName, summary: nil, boundingBoxes: boundingBoxesJSON))
                        } else {
                            consecutiveMBCount = 0
                            startOfIncidentPath = nil
                            peakMacroblockingFramePath = nil
                        }
                    }
                } else {
                    isCurrentMBSeriesVerified = true
                    currentMBVerifiedEngine = "offline"
                    anomalies.append(Anomaly(type: "macroblocking", score: peakMacroblockingScore, engine: "offline", summary: nil, boundingBoxes: boundingBoxesJSON))
                }
            }
        } else {
            // Check if incident cleared
            if isCurrentMBSeriesVerified, let start = startOfIncidentPath, let peak = peakMacroblockingFramePath {
                let endPath = saveCurrentFrameHEIC(data: encodedFrame, thumbnailsDir: thumbnailsDir)
                let tier = await MainActor.run { NativeVLMClient.shared.selectedTier }
                let sessionBackup = await MainActor.run { streamController?.activeSessionName ?? "unknown" }

                isCurrentMBSeriesVerified = false
                startOfIncidentPath = nil
                peakMacroblockingFramePath = nil

                if let end = endPath {
                    Task(priority: .utility) {
                        if let summary = await NativeVLMClient.shared.analyzeStageB(start: start, peak: peak, end: end, tier: tier) {
                            await MainActor.run {
                                streamController?.insertVideoLog(
                                    videoFilename: sessionBackup,
                                    timestampSec: Double(frameCount),
                                    nodeSource: "VLM-Forensic",
                                    nodeBackbone: "East-Backbone-Live",
                                    nodeDest: "Incident Report",
                                    issueType: "macroblocking_incident_summary",
                                    issueScore: 1.0,
                                    analysisEngine: tier.displayName,
                                    thumbnailPath: URL(fileURLWithPath: peak).lastPathComponent,
                                    issueSummary: summary
                                )
                            }
                        }
                    }
                }
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
