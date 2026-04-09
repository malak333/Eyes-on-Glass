import Foundation
import Vapor
import Fluent

actor LiveStreamService {
    static let shared = LiveStreamService()
    
    private var activeProcess: Process?
    private var isActive = false
    private var task: Task<Void, Never>?
    private var activeSessionName: String?
    
    func startMonitoring(uri: String, sessionName: String, db: Database, logger: Logging.Logger, client: Client) async {
        if isActive {
            await stopMonitoring()
        }
        isActive = true
        activeSessionName = sessionName
        task = Task {
            await runLoop(uri: uri, sessionName: sessionName, db: db, logger: logger, client: client)
        }
    }
    
    func stopMonitoring() async {
        isActive = false
        activeProcess?.terminate()
        activeProcess = nil
        task?.cancel()
        task = nil
        if let session = activeSessionName {
            await ExtractionProgress.shared.set(status: "completed", current: 0, total: 0, for: session)
        }
    }
    
    private func runLoop(uri: String, sessionName: String, db: Database, logger: Logging.Logger, client: Client) async {
        var lastOkLogTime = Date().timeIntervalSince1970
        let thumbnailsDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("../backend/thumbnails/")
        try? FileManager.default.createDirectory(at: thumbnailsDir, withIntermediateDirectories: true)
        
        while isActive {
            let process = Process()
            self.activeProcess = process
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            
            process.arguments = [
                "ffmpeg", "-y", "-nostdin", "-v", "error",
                "-i", uri,
                "-vf", "fps=1",
                "-c:v", "mjpeg",
                "-f", "image2pipe",
                "-"
            ]
            let pipe = Pipe()
            process.standardOutput = pipe
            
            do {
                try process.run()
                logger.info("LiveStreamService: FFmpeg started for \(uri)")
            } catch {
                logger.error("LiveStreamService: Failed to start FFmpeg: \(error)")
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                continue
            }
            
            let fileHandle = pipe.fileHandleForReading
            var buffer = Data()
            var frameCount = 0
            
            do {
                for try await chunk in fileHandle.bytes {
                    if !isActive { break }
                    buffer.append(chunk)
                    
                    if buffer.count > 2 && buffer[buffer.count - 2] == 0xFF && buffer[buffer.count - 1] == 0xD9 {
                        // Found JPEG End Of Image
                        let frameData = buffer
                        buffer.removeAll(keepingCapacity: true)
                        
                        let frameID = UUID().uuidString
                        let thumbURL = thumbnailsDir.appendingPathComponent("live_\(frameID).jpg")
                        do {
                            try frameData.write(to: thumbURL)
                            
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
                            
                            if !videoIssueFound && frameCount % 5 == 0 {
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
                                if now - lastOkLogTime >= 60 {
                                    let log = VideoLog()
                                    log.videoFilename = sessionName
                                    log.timestampSec = Double(frameCount)
                                    log.nodeSource = "Live-Multicast"
                                    log.nodeBackbone = "East-Backbone-Live"
                                    log.nodeDest = "Distribution-Node"
                                    log.issueType = "ok"
                                    log.issueScore = 1.0
                                    log.analysisEngine = "avfoundation"
                                    try? await log.save(on: db)
                                    lastOkLogTime = now
                                }
                                
                                // Delete immediately to save space when no issues are found
                                try? FileManager.default.removeItem(at: thumbURL)
                            } else {
                                for (issue, score, engine) in issuesFound {
                                    let log = VideoLog()
                                    log.videoFilename = sessionName
                                    log.timestampSec = Double(frameCount)
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
                            
                            frameCount += 1
                            
                        } catch {
                            logger.error("LiveStreamService: failed to write frame data: \(error)")
                        }
                    }
                }
            } catch {
                logger.error("LiveStreamService: error reading from pipe: \(error)")
            }
            
            process.waitUntilExit()
            if isActive {
                logger.warning("LiveStreamService: FFmpeg exited unexpectedly. Reconnecting in 2 seconds...")
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }
}
