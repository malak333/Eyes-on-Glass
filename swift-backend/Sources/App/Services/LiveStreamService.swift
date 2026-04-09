import Foundation
import Vapor
import Fluent
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
    
    func startMonitoring(uri: String, sessionName: String, db: Database, logger: Logging.Logger, client: Client) async {
        if isActive {
            await stopMonitoring()
        }
        isActive = true
        activeSessionName = sessionName
        lastOkLogTime = 0 // Emit first OK log immediately
        frameCount = 0
        
        let thumbnailsDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("../backend/thumbnails/")
        try? FileManager.default.createDirectory(at: thumbnailsDir, withIntermediateDirectories: true)
        
        let newIngestor = UDPIngestor()
        self.ingestor = newIngestor
        
        Task {
            await newIngestor.start(uri: uri) { pixelBuffer in
                Task {
                    await self.processFrame(pixelBuffer: pixelBuffer, sessionName: sessionName, thumbnailsDir: thumbnailsDir, db: db, logger: logger, client: client)
                }
            }
        }
        logger.info("LiveStreamService: UDPIngestor started for \(uri)")
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
    
    private func processFrame(pixelBuffer: CVPixelBuffer, sessionName: String, thumbnailsDir: URL, db: Database, logger: Logging.Logger, client: Client) async {
        guard isActive, sessionName == activeSessionName else { return }
        
        // Eagerly snapshot and advance frameCount to prevent reentrancy from queueing duplicate tasks.
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
                let (isSlate, conf) = await OllamaClient.analyzeFrame(client: client, imagePath: thumbURL.path, model: "moondream")
                if isSlate {
                    issuesFound.append(("slate", conf, "quick_ai"))
                    videoIssueFound = true
                } else {
                    let (fallbackSlate, fallbackConf) = await OllamaClient.analyzeFrame(client: client, imagePath: thumbURL.path, model: "llava")
                    if fallbackSlate {
                        issuesFound.append(("slate", fallbackConf, "heavy_ai"))
                    }
                }
            }
            
            let now = Date().timeIntervalSince1970
            if issuesFound.isEmpty {
                let log = VideoLog()
                log.videoFilename = sessionName
                log.timestampSec = Double(currentFrameIndex)
                log.nodeSource = "Live-Multicast"
                log.nodeBackbone = "East-Backbone-Live"
                log.nodeDest = "Distribution-Node"
                log.issueType = "ok"
                log.issueScore = 1.0
                log.analysisEngine = "avfoundation"
                try? await log.save(on: db)
                lastOkLogTime = now
                
                try? FileManager.default.removeItem(at: thumbURL)
            } else {
                for (issue, score, engine) in issuesFound {
                    let log = VideoLog()
                    log.videoFilename = sessionName
                    log.timestampSec = Double(currentFrameIndex)
                    log.nodeSource = "Live-Multicast"
                    log.nodeBackbone = "East-Backbone-Live"
                    log.nodeDest = "Distribution-Node"
                    log.issueType = issue
                    log.issueScore = score
                    log.analysisEngine = engine
                    log.thumbnailPath = thumbURL.lastPathComponent
                    try? await log.save(on: db)
                }
            }
            
            await ExtractionProgress.shared.set(status: "extracting", current: frameCount, total: 0, for: sessionName)
            
        } catch {
            logger.error("LiveStreamService: processing error: \(error)")
        }
    }
}
