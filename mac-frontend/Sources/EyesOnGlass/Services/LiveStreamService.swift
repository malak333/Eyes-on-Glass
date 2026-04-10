import SwiftData
import Foundation
import CoreVideo
import CoreImage

actor LiveStreamService {
    static let shared = LiveStreamService()
    
    private var ingestor: UDPIngestor?
    private var isActive = false
    private var lastOkLogTime: TimeInterval = 0
    private var frameCount: Int = 0
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private var wasAudioHealthy: Bool? = nil
    private var activeSessionName: String?
    
    func startMonitoring(uri: String, sessionName: String, ) async {
        if isActive {
            await stopMonitoring()
        }
        isActive = true
        activeSessionName = sessionName
        lastOkLogTime = 0 
        frameCount = 0
        wasAudioHealthy = nil
        
        let thumbnailsDir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents/EyesOnGlass/thumbnails")
        try? FileManager.default.createDirectory(at: thumbnailsDir, withIntermediateDirectories: true)
        
        let newIngestor = UDPIngestor()
        self.ingestor = newIngestor
        
        Task {
            await newIngestor.start(uri: uri, onFrame: { pixelBuffer, audioHealth in
                Task {
                    await self.processFrame(pixelBuffer: pixelBuffer, audioHealth: audioHealth, sessionName: sessionName, thumbnailsDir: thumbnailsDir)
                }
            }, onPacket: { count in
                Task {
                    await ExtractionProgress.shared.setPackets(count, for: sessionName)
                }
            }, onCCError: {
                Task {
                    await StreamController.shared.incrementCCErrors()
                }
            }, onStreamLost: {
                Task {
                    let ts = Double(self.frameCount)
                    await StreamController.shared.insertVideoLog(
                        videoFilename: sessionName,
                        timestampSec: ts,
                        nodeSource: "Live-Multicast",
                        nodeBackbone: "East-Backbone-Live",
                        nodeDest: "Distribution-Node",
                        issueType: "stream_lost",
                        issueScore: 1.0,
                        analysisEngine: "ingestor",
                        thumbnailPath: nil
                    )
                }
            }, onStreamRestored: {
                Task {
                    let ts = Double(self.frameCount)
                    await StreamController.shared.insertVideoLog(
                        videoFilename: sessionName,
                        timestampSec: ts,
                        nodeSource: "Live-Multicast",
                        nodeBackbone: "East-Backbone-Live",
                        nodeDest: "Distribution-Node",
                        issueType: "stream_restored",
                        issueScore: 1.0,
                        analysisEngine: "ingestor",
                        thumbnailPath: nil
                    )
                }
            }, onVideoLost: {
                Task {
                    let ts = Double(self.frameCount)
                    await StreamController.shared.insertVideoLog(
                        videoFilename: sessionName,
                        timestampSec: ts,
                        nodeSource: "Live-Multicast",
                        nodeBackbone: "East-Backbone-Live",
                        nodeDest: "Distribution-Node",
                        issueType: "video_lost",
                        issueScore: 1.0,
                        analysisEngine: "ingestor",
                        thumbnailPath: nil
                    )
                }
            }, onVideoRestored: {
                Task {
                    let ts = Double(self.frameCount)
                    await StreamController.shared.insertVideoLog(
                        videoFilename: sessionName,
                        timestampSec: ts,
                        nodeSource: "Live-Multicast",
                        nodeBackbone: "East-Backbone-Live",
                        nodeDest: "Distribution-Node",
                        issueType: "video_restored",
                        issueScore: 1.0,
                        analysisEngine: "ingestor",
                        thumbnailPath: nil
                    )
                }
            })
        }
        appLogger.info("LiveStreamService: UDPIngestor started for \(uri, privacy: .public)")
    }
    
    func stopMonitoring() async {
        isActive = false
        await ingestor?.stop()
        ingestor = nil
        if let session = activeSessionName {
            await ExtractionProgress.shared.set(status: "completed", current: 0, total: 0, for: session)
        }
        activeSessionName = nil
    }
    
    private func processFrame(pixelBuffer: CVPixelBuffer, audioHealth: AudioHealth, sessionName: String, thumbnailsDir: URL, ) async {
        guard isActive, sessionName == activeSessionName else { return }
        
        let currentFrameIndex = frameCount
        frameCount += 1
        
        let isAudioHealthy = (audioHealth == .healthy)
        if let previous = wasAudioHealthy {
            if previous && !isAudioHealthy {
                await StreamController.shared.insertVideoLog(
                    videoFilename: sessionName,
                    timestampSec: Double(currentFrameIndex),
                    nodeSource: "Live-Multicast",
                    nodeBackbone: "East-Backbone-Live",
                    nodeDest: "Distribution-Node",
                    issueType: "audio_lost",
                    issueScore: 1.0,
                    analysisEngine: "ingestor",
                    thumbnailPath: nil
                )
            } else if !previous && isAudioHealthy {
                await StreamController.shared.insertVideoLog(
                    videoFilename: sessionName,
                    timestampSec: Double(currentFrameIndex),
                    nodeSource: "Live-Multicast",
                    nodeBackbone: "East-Backbone-Live",
                    nodeDest: "Distribution-Node",
                    issueType: "audio_restored",
                    issueScore: 1.0,
                    analysisEngine: "ingestor",
                    thumbnailPath: nil
                )
            }
        }
        wasAudioHealthy = isAudioHealthy
        
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return }
        guard let jpegData = ciContext.jpegRepresentation(of: ciImage, colorSpace: colorSpace, options: [:]) else { return }
        
        let frameID = UUID().uuidString
        let thumbURL = thumbnailsDir.appendingPathComponent("live_\(frameID).jpg")
        
        do {
            try jpegData.write(to: thumbURL)
            
            let cvResults = VisionAnalyzer.analyze(imagePath: thumbURL.path)
            var issuesFound: [(String, Double, String)] = []
            var videoIssueFound = false
            
            if let cv = cvResults {
                if cv.isBlackScreen {
                    issuesFound.append(("black_screen", 1.0, "opencv"))
                    videoIssueFound = true
                } else {
                    if cv.isBars { issuesFound.append(("bars_and_tone", 1.0, "opencv")); videoIssueFound = true }
                    if cv.isSnowflakes { issuesFound.append(("snowflakes", 1.0, "opencv")); videoIssueFound = true }
                    if cv.isBlurry { issuesFound.append(("blur", 1.0, "opencv")); videoIssueFound = true }
                    let macroConfidence = min(1.0, max(0.0, (cv.blockiness - 1.25) / 0.5))
                    if macroConfidence >= 0.50 && cv.laplacianVariance > 30.0 {
                        issuesFound.append(("macroblocking", Double(macroConfidence), "opencv")); videoIssueFound = true
                    }
                    if cv.hasTopArtifact {
                        issuesFound.append(("top_artifact", 1.0, "opencv")); videoIssueFound = true
                    }
                }
            }
            
            if !videoIssueFound && currentFrameIndex % 5 == 0 {
                let tier = await MainActor.run { NativeVLMClient.shared.selectedTier }
                let (isSlate, conf) = await NativeVLMClient.shared.analyzeFrame(imagePath: thumbURL.path, tier: tier)
                if isSlate {
                    issuesFound.append(("slate", conf, "native_vlm_\(tier.rawValue)"))
                    videoIssueFound = true
                }
            }
            
            let now = Date().timeIntervalSince1970
            if issuesFound.isEmpty {
                await StreamController.shared.insertVideoLog(
                    videoFilename: sessionName,
                    timestampSec: Double(currentFrameIndex),
                    nodeSource: "Live-Multicast",
                    nodeBackbone: "East-Backbone-Live",
                    nodeDest: "Distribution-Node",
                    issueType: "ok",
                    issueScore: 1.0,
                    analysisEngine: "avfoundation",
                    thumbnailPath: nil
                )
                
                lastOkLogTime = now
                try? FileManager.default.removeItem(at: thumbURL)
            } else {
                for (issue, score, engine) in issuesFound {
                    await StreamController.shared.insertVideoLog(
                        videoFilename: sessionName,
                        timestampSec: Double(currentFrameIndex),
                        nodeSource: "Live-Multicast",
                        nodeBackbone: "East-Backbone-Live",
                        nodeDest: "Distribution-Node",
                        issueType: issue,
                        issueScore: score,
                        analysisEngine: engine,
                        thumbnailPath: thumbURL.lastPathComponent
                    )
                }
            }
            
            await ExtractionProgress.shared.set(status: "extracting", current: frameCount, total: 0, for: sessionName)
            
        } catch {
            appLogger.error("LiveStreamService: processing error: \(error, privacy: .public)")
        }
    }
}
