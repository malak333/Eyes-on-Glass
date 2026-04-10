import SwiftData
import Foundation
import CoreVideo
import CoreImage

actor LiveStreamService {
    static let shared = LiveStreamService()
    
    private var ingestor: UDPIngestor?
    private var isActive = false
    private var activeSessionName: String?
    
    private var lastOkLogTime: TimeInterval = 0
    private var frameCount: Int = 0
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    
    func startMonitoring(uri: String, sessionName: String, ) async {
        if isActive {
            await stopMonitoring()
        }
        isActive = true
        activeSessionName = sessionName
        lastOkLogTime = 0 
        frameCount = 0
        
        let thumbnailsDir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents/EyesOnGlass/thumbnails")
        try? FileManager.default.createDirectory(at: thumbnailsDir, withIntermediateDirectories: true)
        
        let newIngestor = UDPIngestor()
        self.ingestor = newIngestor
        
        Task {
            await newIngestor.start(uri: uri, onFrame: { pixelBuffer in
                Task {
                    await self.processFrame(pixelBuffer: pixelBuffer, sessionName: sessionName, thumbnailsDir: thumbnailsDir)
                }
            }, onPacket: { count in
                Task {
                    await ExtractionProgress.shared.setPackets(count, for: sessionName)
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
    
    private func processFrame(pixelBuffer: CVPixelBuffer, sessionName: String, thumbnailsDir: URL, ) async {
        guard isActive, sessionName == activeSessionName else { return }
        
        let currentFrameIndex = frameCount
        frameCount += 1
        
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
                let (isSlate, conf) = await OllamaClient.analyzeFrame(imagePath: thumbURL.path, model: "moondream")
                if isSlate {
                    issuesFound.append(("slate", conf, "quick_ai"))
                    videoIssueFound = true
                } else {
                    let (fallbackSlate, fallbackConf) = await OllamaClient.analyzeFrame(imagePath: thumbURL.path, model: "llava")
                    if fallbackSlate {
                        issuesFound.append(("slate", fallbackConf, "heavy_ai"))
                    }
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
