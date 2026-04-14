import SwiftData
import Foundation
import CoreVideo
import CoreImage
import SwiftUI
import SwiftUI
import AppKit

class UIVisualsRenderer: @unchecked Sendable {
    static let shared = UIVisualsRenderer()
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private var isRenderingVideo = false
    private let videoQueue = DispatchQueue(label: "com.eyesonGlass.uiVideoRenderer")
    private var isRenderingAudio = false
    private let audioQueue = DispatchQueue(label: "com.eyesonGlass.uiAudioRenderer")
    
    private var lastVideoRenderTime: TimeInterval = 0
    private var lastAudioRenderTime: TimeInterval = 0

    func render(pixelBuffer: CVPixelBuffer) {
        videoQueue.async {
            let now = CFAbsoluteTimeGetCurrent()
            guard now - self.lastVideoRenderTime >= 1.0 / 30.0 else { return }
            guard !self.isRenderingVideo else { return }
            self.isRenderingVideo = true
            
            Task {
                let isVisible = await MainActor.run { StreamController.shared.isAdvancedInspectorVisible }
                if isVisible {
                    let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
                    if let cgImage = self.ciContext.createCGImage(ciImage, from: ciImage.extent) {
                        let nsImage = NSImage(cgImage: cgImage, size: ciImage.extent.size)
                        await MainActor.run {
                            StreamController.shared.currentFrameImage = Image(nsImage: nsImage)
                        }
                    }
                }
                
                self.videoQueue.async {
                    self.lastVideoRenderTime = CFAbsoluteTimeGetCurrent()
                    self.isRenderingVideo = false
                }
            }
        }
    }
    
    func render(waveform: [Float], vectorscope: [CGPoint], phase: [Float], levels: [Float]) {
        audioQueue.async {
            let now = CFAbsoluteTimeGetCurrent()
            guard now - self.lastAudioRenderTime >= 1.0 / 30.0 else { return }
            guard !self.isRenderingAudio else { return }
            self.isRenderingAudio = true
            
            Task {
                let isVisible = await MainActor.run { StreamController.shared.isAdvancedInspectorVisible }
                if isVisible {
                    await MainActor.run {
                        StreamController.shared.audioWaveformData = waveform
                        StreamController.shared.audioVectorscopeData = vectorscope
                        StreamController.shared.audioPhaseData = phase
                        StreamController.shared.audioLevelsData = levels
                    }
                }
                
                self.audioQueue.async {
                    self.lastAudioRenderTime = CFAbsoluteTimeGetCurrent()
                    self.isRenderingAudio = false
                }
            }
        }
    }
}

actor LiveStreamService {
    static let shared = LiveStreamService()
    
    private var ingestor: UDPIngestor?
    private var isActive = false
    private var lastOkLogTime: TimeInterval = 0
    private var lastIssueEncounteredTime: TimeInterval = 0
    private var isPendingRecovery: Bool = true
    private var frameCount: Int = 0
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private var wasAudioHealthy: Bool? = nil
    private var activeSessionName: String?
    
    func recordIssueState() {
        lastIssueEncounteredTime = Date().timeIntervalSince1970
        isPendingRecovery = true
    }
    
    // Ring Buffer for visual UI and Evidence export (30 frames max)
    private var visualRingBuffer: [Data] = []
    
    // Macroblocking Series State
    private var lastMacroblockingIndex: Int = -2
    private var isCurrentMBSeriesVerified: Bool = false
    private var isStageAVerifying: Bool = false
    private var currentMBVerifiedEngine: String = "opencv"
    private var peakMacroblockingScore: Double = 0.0
    private var peakMacroblockingFramePath: String?
    private var startOfIncidentPath: String?
    
    private func getPreviousFrameHEIC(thumbnailsDir: URL) -> String? {
        guard let data = visualRingBuffer.first else { return nil }
        let url = thumbnailsDir.appendingPathComponent("live_prior_\(UUID().uuidString).heic")
        try? data.write(to: url)
        return url.path
    }
    
    func getStreamInfo() async -> (videoPID: UInt16?, audioPID: UInt16?, resolution: CGSize?, audioSampleRate: Int?, audioChannels: Int?, audioCodec: String?, audioBitrate: Double?, audioLoudness: Double?, audioTruePeak: Double?, audioDialNorm: Int?, tsID: UInt16?, programID: UInt16?, servicesCount: Int, sdtChannel: String?, sdtProvider: String?, videoColor: String?, videoGOPSize: Int?, videoFrameRate: Double?, tsClock: String?, pcrJitter: Double?, pcrInterval: Double?) {
        if let ingestor = ingestor {
            return await ingestor.streamInfo
        }
        return (nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, 0, nil, nil, nil, nil, nil, nil, nil, nil)
    }
    
    func getAudioVisuals() async -> (waveform: [Float], vectorscope: [CGPoint], phase: [Float], levels: [Float])? {
        if let ingestor = ingestor {
            return await ingestor.audioVisuals
        }
        return nil
    }
    
    func startMonitoring(uri: String, sessionName: String, ) async {
        if isActive {
            await stopMonitoring()
        }
        isActive = true
        activeSessionName = sessionName
        lastOkLogTime = 0 
        lastIssueEncounteredTime = Date().timeIntervalSince1970
        isPendingRecovery = true
        frameCount = 0
        wasAudioHealthy = nil
        lastMacroblockingIndex = -2
        isCurrentMBSeriesVerified = false
        isStageAVerifying = false
        currentMBVerifiedEngine = "opencv"
        visualRingBuffer.removeAll()
        
        let thumbnailsDir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents/EyesOnGlass/thumbnails")
        try? FileManager.default.createDirectory(at: thumbnailsDir, withIntermediateDirectories: true)
        
        let newIngestor = UDPIngestor()
        self.ingestor = newIngestor
        
        Task(priority: .userInitiated) {
            await newIngestor.start(uri: uri, onFrame: { pixelBuffer, audioHealth in
                Task(priority: .userInitiated) {
                    await self.processFrame(pixelBuffer: pixelBuffer, audioHealth: audioHealth, sessionName: sessionName, thumbnailsDir: thumbnailsDir)
                }
            }, onVideoFrame: { pixelBuffer in
                UIVisualsRenderer.shared.render(pixelBuffer: pixelBuffer)
            }, onAudioVisuals: { waveform, vectorscope, phase, levels in
                UIVisualsRenderer.shared.render(waveform: waveform, vectorscope: vectorscope, phase: phase, levels: levels)
            }, onPacket: { count in
                Task(priority: .utility) {
                    await ExtractionProgress.shared.setPackets(count, for: sessionName)
                }
            }, onCCError: {
                Task(priority: .utility) {
                    await StreamController.shared.incrementCCErrors()
                }
            }, onStreamLost: {
                Task(priority: .utility) {
                    self.recordIssueState()
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
                Task(priority: .utility) {
                    self.recordIssueState()
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
                Task(priority: .utility) {
                    self.recordIssueState()
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
                Task(priority: .utility) {
                    self.recordIssueState()
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
        appLogger.info("LiveStreamService: UDPIngestor started for \\(uri, privacy: .public)")
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
    
    func setMuted(_ muted: Bool) async {
        await ingestor?.setMuted(muted)
    }
    
    private func processFrame(pixelBuffer: CVPixelBuffer, audioHealth: AudioHealth, sessionName: String, thumbnailsDir: URL, ) async {
        guard isActive, sessionName == activeSessionName else { return }
        
        let now = Date().timeIntervalSince1970
        let currentFrameIndex = frameCount
        frameCount += 1
        
        let isAudioHealthy = (audioHealth == .healthy)
        if let previous = wasAudioHealthy {
            if previous != isAudioHealthy {
                recordIssueState()
            }
        } else if !isAudioHealthy {
            recordIssueState()
        }
        
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
        
        // Use HEIC compression via M-series Media Engine for ring buffer hardware optimization
        var currentFrameHEIC: Data? = nil
        if let heicData = ciContext.heifRepresentation(of: ciImage, format: .RGBA8, colorSpace: colorSpace, options: [:]) {
            currentFrameHEIC = heicData
            visualRingBuffer.append(heicData)
            if visualRingBuffer.count > 30 {
                visualRingBuffer.removeFirst()
            }
        }
        
        let frameID = UUID().uuidString
        let thumbURL = thumbnailsDir.appendingPathComponent("live_\(frameID).heic")
        var savedThumbPath: String? = nil
        var retainFileOnDisk = false
        
        let cvResults = VisionAnalyzer.analyze(ciImage: ciImage, context: ciContext)
        var issuesFound: [(String, Double, String)] = []
        var needsDiskWrite = false
            
            if let cv = cvResults {
                if cv.isBlackScreen {
                    issuesFound.append(("black_screen", 1.0, "opencv"))
                    needsDiskWrite = true
                } else {
                    if cv.isBars { issuesFound.append(("bars_and_tone", 1.0, "opencv")); needsDiskWrite = true }
                    if cv.isSnowflakes { issuesFound.append(("snowflakes", 1.0, "opencv")); needsDiskWrite = true }
                    let macroConfidence = min(1.0, max(0.0, (cv.blockiness - 1.25) / 0.5))
                    appLogger.info("LiveStreamService MB Check - Frame \(currentFrameIndex): blockiness=\(cv.blockiness), variance=\(cv.laplacianVariance), conf=\(macroConfidence)")
                    
                    if macroConfidence >= 0.15 && cv.laplacianVariance > 15.0 {
                        needsDiskWrite = true
                    }
                    if cv.hasTopArtifact {
                        issuesFound.append(("top_artifact", 1.0, "opencv"))
                        needsDiskWrite = true
                    }
                }
            }
            
            if issuesFound.isEmpty && isCurrentMBSeriesVerified && startOfIncidentPath != nil && peakMacroblockingFramePath != nil {
                needsDiskWrite = true
            }
            
            if needsDiskWrite {
                if let heicData = currentFrameHEIC {
                    do {
                        try heicData.write(to: thumbURL)
                        savedThumbPath = thumbURL.path
                    } catch {
                        appLogger.error("LiveStreamService: failed to write frame: \(error, privacy: .public)")
                    }
                }
            }
            
            if let cv = cvResults, !cv.isBlackScreen {
                let macroConfidence = min(1.0, max(0.0, (cv.blockiness - 1.25) / 0.5))
                if macroConfidence >= 0.15 && cv.laplacianVariance > 15.0 {
                    let seriesGap = currentFrameIndex - lastMacroblockingIndex
                    let wasGap = seriesGap > 1
                    
                    lastMacroblockingIndex = currentFrameIndex
                    
                    if wasGap && !isStageAVerifying {
                        // New series, verify it (Stage A)
                        let tier = await MainActor.run { NativeVLMClient.shared.selectedTier }
                        let isVlmReady = await MainActor.run { 
                            if case .ready = NativeVLMClient.shared.state { return true }
                            return false 
                        }
                        
                        startOfIncidentPath = savedThumbPath
                        peakMacroblockingScore = Double(macroConfidence)
                        peakMacroblockingFramePath = savedThumbPath
                        
                        isCurrentMBSeriesVerified = false // Guarantee reset
                        
                        if isVlmReady {
                            if let priorPath = getPreviousFrameHEIC(thumbnailsDir: thumbnailsDir), let currentPath = savedThumbPath {
                                isStageAVerifying = true
                                let isVerified = await NativeVLMClient.shared.analyzeStageA(lastGood: priorPath, bad: currentPath, tier: tier)
                                isStageAVerifying = false
                                isCurrentMBSeriesVerified = isVerified
                                currentMBVerifiedEngine = tier.displayName
                                
                                if isVerified {
                                    issuesFound.append(("🔴 Potential Macroblocking Detected (Initial Check)", Double(macroConfidence), tier.displayName))
                                } else {
                                    startOfIncidentPath = nil
                                    peakMacroblockingFramePath = nil
                                    appLogger.info("LLM rejected live macroblocking detection at \(currentFrameIndex)s.")
                                }
                            }
                        } else {
                            isCurrentMBSeriesVerified = false
                            startOfIncidentPath = nil
                            peakMacroblockingFramePath = nil
                            appLogger.error("Local LLM model isn't available to verify macroblocking. Dropping unverified logs.")
                        }
                    } else {
                        // Continuing series or evaluating during suspends
                        if let currentPath = savedThumbPath, Double(macroConfidence) > peakMacroblockingScore {
                            peakMacroblockingScore = Double(macroConfidence)
                            peakMacroblockingFramePath = currentPath
                        }
                        
                        if isCurrentMBSeriesVerified {
                            issuesFound.append(("macroblocking", Double(macroConfidence), currentMBVerifiedEngine))
                        } else if isStageAVerifying {
                            issuesFound.append(("macroblocking_verifying", Double(macroConfidence), "Verifying..."))
                        }
                    }
                }
            }
            
            let tier = await MainActor.run { NativeVLMClient.shared.selectedTier }
            
            if issuesFound.isEmpty {
                // Check if an incident just cleared (Stage B)
                if isCurrentMBSeriesVerified, let start = startOfIncidentPath, let peak = peakMacroblockingFramePath, let endPath = savedThumbPath {
                    let sessionBackup = sessionName
                    let indexBackup = currentFrameIndex
                    
                    isCurrentMBSeriesVerified = false
                    startOfIncidentPath = nil
                    peakMacroblockingFramePath = nil
                    retainFileOnDisk = true
                    
                    Task(priority: .utility) {
                        if let summary = await NativeVLMClient.shared.analyzeStageB(start: start, peak: peak, end: endPath, tier: tier) {
                            appLogger.info("Stage B incident report generated: \(summary)")
                            await StreamController.shared.insertVideoLog(
                                videoFilename: sessionBackup,
                                timestampSec: Double(indexBackup),
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
            
                let isVlmReady = await MainActor.run {
                    if case .ready = NativeVLMClient.shared.state { return true }
                    return false
                }
                let defaultEngine = LiveStreamService.determineDefaultEngine(isVlmReady: isVlmReady, frameIndex: currentFrameIndex, tierName: tier.displayName)
                
                if isAudioHealthy {
                    let timeSinceLastIssue = now - lastIssueEncounteredTime
                    var shouldLogOk = false
                    
                    if isPendingRecovery {
                        if timeSinceLastIssue >= 3.0 {
                            shouldLogOk = true
                            isPendingRecovery = false
                        }
                    } else {
                        let timeSinceLastOk = now - lastOkLogTime
                        if timeSinceLastOk >= 600.0 {
                            shouldLogOk = true
                        }
                    }
                    
                    if shouldLogOk {
                        await StreamController.shared.insertVideoLog(
                            videoFilename: sessionName,
                            timestampSec: Double(currentFrameIndex),
                            nodeSource: "Live-Multicast",
                            nodeBackbone: "East-Backbone-Live",
                            nodeDest: "Distribution-Node",
                            issueType: "ok",
                            issueScore: 1.0,
                            analysisEngine: defaultEngine,
                            thumbnailPath: nil
                        )
                        lastOkLogTime = now
                    }
                }
            } else {
                recordIssueState()
                retainFileOnDisk = true
                
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
                        thumbnailPath: savedThumbPath != nil ? URL(fileURLWithPath: savedThumbPath!).lastPathComponent : nil
                    )
                }
            }
            
            if !retainFileOnDisk {
                try? FileManager.default.removeItem(at: thumbURL)
            }
            
            await ExtractionProgress.shared.set(status: "extracting", current: frameCount, total: 0, for: sessionName)
    }
    
    // Removed updateVideoView and updateAudioView methods
    
    static func determineDefaultEngine(isVlmReady: Bool, frameIndex: Int, tierName: String) -> String {
        return (isVlmReady && frameIndex % 5 == 0) ? tierName : "opencv"
    }
}
