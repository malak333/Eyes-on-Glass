import SwiftData
import Foundation
import CoreVideo
import CoreImage
import SwiftUI
import SwiftUI
import AppKit

class UIVisualsRenderer: @unchecked Sendable {
    private weak var streamController: StreamController?

    init(streamController: StreamController?) {
        self.streamController = streamController
    }

    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private var isRenderingVideo = false
    private let videoQueue = DispatchQueue(label: "com.eyesonGlass.uiVideoRenderer")
    private var isRenderingAudio = false
    private let audioQueue = DispatchQueue(label: "com.eyesonGlass.uiAudioRenderer")
    
    private var lastVideoRenderTime: TimeInterval = 0
    private var lastAudioRenderTime: TimeInterval = 0

    func render(pixelBuffer: CVPixelBuffer) {
        // Core Animation AVSampleBufferDisplayLayer natively handles its own execution threading and frame drops.
        // Bypassing MainActor to achieve zero-copy propagation!
        streamController?.videoFrameSubject.send(pixelBuffer)
    }
    
    func render(waveform: [Float], vectorscope: [CGPoint], phase: [Float], levels: [Float]) {
        audioQueue.async {
            let now = CFAbsoluteTimeGetCurrent()
            guard now - self.lastAudioRenderTime >= 1.0 / 30.0 else { return }
            guard !self.isRenderingAudio else { return }
            self.isRenderingAudio = true
            
            Task {
                let isVisible = await MainActor.run { self.streamController?.isAdvancedInspectorVisible == true }
                if isVisible {
                    await MainActor.run {
                        self.streamController?.audioWaveformData = waveform
                        self.streamController?.audioVectorscopeData = vectorscope
                        self.streamController?.audioPhaseData = phase
                        self.streamController?.audioLevelsData = levels
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
    private weak var streamController: StreamController?
    private let visualsRenderer: UIVisualsRenderer

    init(streamController: StreamController?) {
        self.streamController = streamController
        self.visualsRenderer = UIVisualsRenderer(streamController: streamController)
    }
    
    private var ingestor: UDPIngestor?
    private var isActive = false
    private var lastOkLogTime: TimeInterval = 0
    private var lastIssueEncounteredTime: TimeInterval = 0
    private var isPendingRecovery: Bool = true
    private var frameCount: Int = 0
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private var activeSessionName: String?
    private var pendingCCErrorsCount: Int = 0
    private var lastFrameProcessTime: TimeInterval = 0
    private var audioLossStartTime: TimeInterval? = nil
    private var wasAudioHealthy: Bool? = nil

    func incrementPendingCCErrors() {
        pendingCCErrorsCount += 1
    }
    
    func popPendingCCErrors() -> Int {
        let count = pendingCCErrorsCount
        pendingCCErrorsCount = 0
        return count
    }
    
    func recordIssueState() {
        lastIssueEncounteredTime = Date().timeIntervalSince1970
        isPendingRecovery = true
    }
    
    // Ring Buffer for visual UI and Evidence export (30 frames max)
    private var visualRingBuffer: [Data] = []
    
    // Macroblocking Series State
    private var lastMacroblockingIndex: Int = -2
    private var isCurrentMBSeriesVerified: Bool = false
    public var isStageAVerifying: Bool = false
    
    // Black Screen Detection State
    private var isCurrentlyBlackScreen: Bool = false
    private var blackScreenStartTime: TimeInterval? = nil
    private var preBlackScreenFramePath: String? = nil
    private var representativeBlackFramePath: String? = nil
    
    // For unit testing
    public func setStageAVerifyingStatus(_ val: Bool) {
        self.isStageAVerifying = val
    }
    
    private var consecutiveMBCount: Int = 0
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
    
    private func saveCurrentFrameHEIC(thumbnailsDir: URL, currentData: Data?) -> String? {
        guard let data = currentData else { return nil }
        let url = thumbnailsDir.appendingPathComponent("live_event_\(UUID().uuidString).heic")
        try? data.write(to: url)
        return url.path
    }
    
    func getStreamInfo() async -> (videoPID: UInt16?, audioPID: UInt16?, videoCodec: String?, resolution: CGSize?, audioSampleRate: Int?, audioChannels: Int?, audioCodec: String?, audioBitrate: Double?, audioLoudness: Double?, audioTruePeak: Double?, audioDialNorm: Int?, tsID: UInt16?, programID: UInt16?, servicesCount: Int, sdtChannel: String?, sdtProvider: String?, videoColor: String?, videoGOPSize: Int?, videoFrameRate: Double?, tsClock: String?, pcrJitter: Double?, pcrInterval: Double?) {
        if let ingestor = ingestor {
            return await ingestor.streamInfo
        }
        return (nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, 0, nil, nil, nil, nil, nil, nil, nil, nil)
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
        audioLossStartTime = nil
        lastMacroblockingIndex = -2
        isCurrentMBSeriesVerified = false
        consecutiveMBCount = 0
        isStageAVerifying = false
        isCurrentlyBlackScreen = false
        blackScreenStartTime = nil
        preBlackScreenFramePath = nil
        representativeBlackFramePath = nil
        currentMBVerifiedEngine = "opencv"
        lastFrameProcessTime = 0
        visualRingBuffer.removeAll()
        
        let thumbnailsDir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents/EyesOnGlass/thumbnails")
        try? FileManager.default.createDirectory(at: thumbnailsDir, withIntermediateDirectories: true)
        
        let newIngestor = UDPIngestor()
        self.ingestor = newIngestor
        
        Task(priority: .userInitiated) {
            await newIngestor.start(uri: uri, onFrame: { pixelBuffer, audioHealth, networkIAT in
                Task(priority: .userInitiated) {
                    await self.processFrame(pixelBuffer: pixelBuffer, audioHealth: audioHealth, networkIAT: networkIAT, sessionName: sessionName, thumbnailsDir: thumbnailsDir)
                }
            }, onVideoFrame: { pixelBuffer in
                self.visualsRenderer.render(pixelBuffer: pixelBuffer)
            }, onAudioVisuals: { waveform, vectorscope, phase, levels in
                self.visualsRenderer.render(waveform: waveform, vectorscope: vectorscope, phase: phase, levels: levels)
            }, onPacket: { count in
                Task(priority: .utility) {
                    await ExtractionProgress.shared.setPackets(count, for: sessionName)
                }
            }, onCCError: {
                Task(priority: .utility) {
                    await self.incrementPendingCCErrors()
                }
            }, onStreamLost: {
                Task(priority: .utility) {
                    self.recordIssueState()
                    let ts = Double(self.frameCount)
                    self.streamController?.enqueueVideoLog(
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
                    self.streamController?.enqueueVideoLog(
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
                    self.streamController?.enqueueVideoLog(
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
                    self.streamController?.enqueueVideoLog(
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
    
    private func processFrame(pixelBuffer: CVPixelBuffer, audioHealth: AudioHealth, networkIAT: Double, sessionName: String, thumbnailsDir: URL) async {
        guard isActive, sessionName == activeSessionName else { return }
        
        let now = Date().timeIntervalSince1970
        let currentFrameIndex = frameCount
        frameCount += 1
        
        let nowTime = CFAbsoluteTimeGetCurrent()
        let iatMs = networkIAT
        lastFrameProcessTime = nowTime
        
        let localController = self.streamController
        Task { @MainActor [localController] in
            localController?.updateIAT(iatMs)
        }
        
        let currentCCErrors = pendingCCErrorsCount
        pendingCCErrorsCount = 0
        
        let isAudioHealthy = (audioHealth == .healthy)
        
        if isAudioHealthy {
            audioLossStartTime = nil
            if let previous = wasAudioHealthy {
                if !previous {
                    recordIssueState()
                    self.streamController?.enqueueVideoLog(
                        videoFilename: sessionName,
                        timestampSec: Double(currentFrameIndex),
                        nodeSource: "Live-Multicast",
                        nodeBackbone: "East-Backbone-Live",
                        nodeDest: "Distribution-Node",
                        issueType: "audio_restored",
                        issueScore: 1.0,
                        analysisEngine: "ingestor",
                        thumbnailPath: nil,
                        iatMs: iatMs
                    )
                }
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
                        recordIssueState()
                        self.streamController?.enqueueVideoLog(
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
                    }
                } else {
                    recordIssueState()
                }
                wasAudioHealthy = false
            }
        }
        
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
        var issuesFound: [(String, Double, String, String?, String?)] = []
        var needsDiskWrite = false
            
        if currentCCErrors > 0 {
            let errorText = "\(currentCCErrors) CC Error\(currentCCErrors > 1 ? "s" : "")"
            issuesFound.append(("cc_error", 1.0, "ingestor", "\(errorText) Detected", nil))
            needsDiskWrite = true
        }
        
        if iatMs > 40.0 {
            issuesFound.append(("high_iat", 1.0, "ingestor", String(format: "IAT spiked to %.1f ms", iatMs), nil))
            needsDiskWrite = true
        }

            if let cv = cvResults {
                if cv.isBlackScreen {
                    if !isCurrentlyBlackScreen {
                        isCurrentlyBlackScreen = true
                        blackScreenStartTime = nowTime
                        preBlackScreenFramePath = getPreviousFrameHEIC(thumbnailsDir: thumbnailsDir)
                        representativeBlackFramePath = saveCurrentFrameHEIC(thumbnailsDir: thumbnailsDir, currentData: currentFrameHEIC)
                    } else if let startTime = blackScreenStartTime, nowTime - startTime >= 7.0 {
                        // Timeout reached, this is a technical failure
                        issuesFound.append(("black_screen", 1.0, "opencv", "Timeout exceeded without recovery", nil))
                        needsDiskWrite = true
                        // Reset so we don't spam
                        isCurrentlyBlackScreen = false
                        blackScreenStartTime = nil
                        preBlackScreenFramePath = nil
                        representativeBlackFramePath = nil
                    }
                } else {
                    if isCurrentlyBlackScreen {
                        let restorationFramePath = saveCurrentFrameHEIC(thumbnailsDir: thumbnailsDir, currentData: currentFrameHEIC)
                        
                        if let prePath = preBlackScreenFramePath, let repPath = representativeBlackFramePath, let endPath = restorationFramePath {
                            let tier = await MainActor.run { NativeVLMClient.shared.selectedTier }
                            let sessionBackup = sessionName
                            let indexBackup = currentFrameIndex
                            let iatMsBackup = iatMs
                            
                            Task(priority: .utility) {
                                let (isFailure, reason) = await NativeVLMClient.shared.analyzeBlackScreenTransition(preFrame: prePath, blackFrame: repPath, endFrame: endPath, tier: tier)
                                if isFailure {
                                    appLogger.info("Black screen transition deemed FAILURE by VLM. Logging issue.")
                                    self.streamController?.enqueueVideoLog(
                                        videoFilename: sessionBackup,
                                        timestampSec: Double(indexBackup),
                                        nodeSource: "Live-Multicast",
                                        nodeBackbone: "East-Backbone-Live",
                                        nodeDest: "Distribution-Node",
                                        issueType: "black_screen",
                                        issueScore: 1.0,
                                        analysisEngine: tier.displayName,
                                        thumbnailPath: URL(fileURLWithPath: repPath).lastPathComponent,
                                        issueSummary: reason,
                                        iatMs: iatMsBackup
                                    )
                                } else {
                                    appLogger.info("Black screen transition deemed CREATIVE by VLM. Dropping issue.")
                                }
                            }
                        }
                        
                        isCurrentlyBlackScreen = false
                        blackScreenStartTime = nil
                        preBlackScreenFramePath = nil
                        representativeBlackFramePath = nil
                    }

                    if cv.isBars { issuesFound.append(("bars_and_tone", 1.0, "opencv", nil, nil)); needsDiskWrite = true }
                    if cv.isSnowflakes { issuesFound.append(("snowflakes", 1.0, "opencv", nil, nil)); needsDiskWrite = true }
                    let macroConfidence = cv.macroConfidence
                    let logString = "LiveStreamService MB Check - Frame \(currentFrameIndex): blockiness=\(cv.blockiness), variance=\(cv.laplacianVariance), conf=\(macroConfidence), boxes=\(cv.anomalyBoundingBoxes.count), isMB=\(cv.isDefinitivelyMacroblocked)\n"
                    if let fileHandle = try? FileHandle(forWritingTo: URL(fileURLWithPath: "/tmp/mb_log.txt")) {
                        fileHandle.seekToEndOfFile()
                        fileHandle.write(logString.data(using: .utf8)!)
                        try? fileHandle.close()
                    } else {
                        try? logString.data(using: .utf8)!.write(to: URL(fileURLWithPath: "/tmp/mb_log.txt"))
                    }
                    
                    let definitivelyMacroblocked = cv.isDefinitivelyMacroblocked
                    if definitivelyMacroblocked {
                        needsDiskWrite = true
                    }
                    if cv.hasTopArtifact {
                        issuesFound.append(("top_artifact", 1.0, "opencv", nil, nil))
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
            
            var boundingBoxesJSON: String? = nil
            if let cv = cvResults, !cv.isBlackScreen {
                let macroConfidence = cv.macroConfidence
                let definitivelyMacroblocked = cv.isDefinitivelyMacroblocked
                if definitivelyMacroblocked {
                    
                    if !cv.anomalyBoundingBoxes.isEmpty {
                        // Extract [CGRect] to [[CGFloat]] basically
                        let boxesArray = cv.anomalyBoundingBoxes.map { [
                            $0.origin.x, $0.origin.y, $0.size.width, $0.size.height
                        ]}
                        if let data = try? JSONSerialization.data(withJSONObject: boxesArray),
                           let jsonString = String(data: data, encoding: .utf8) {
                            boundingBoxesJSON = jsonString
                        }
                    }

                    let seriesGap = currentFrameIndex - lastMacroblockingIndex
                    let wasGap = seriesGap > 1
                    
                    lastMacroblockingIndex = currentFrameIndex
                    
                    if wasGap {
                        isCurrentMBSeriesVerified = false
                        consecutiveMBCount = 1
                        startOfIncidentPath = savedThumbPath
                        peakMacroblockingScore = Double(macroConfidence)
                        peakMacroblockingFramePath = savedThumbPath
                        retainFileOnDisk = true
                    } else {
                        consecutiveMBCount += 1
                        if let currentPath = savedThumbPath, Double(macroConfidence) > peakMacroblockingScore {
                            peakMacroblockingScore = Double(macroConfidence)
                            peakMacroblockingFramePath = currentPath
                            retainFileOnDisk = true
                        }
                    }
                    
                    if isCurrentMBSeriesVerified {
                        issuesFound.append(("macroblocking", Double(macroConfidence), currentMBVerifiedEngine, nil, boundingBoxesJSON))
                    } else if consecutiveMBCount == 2 {
                        let logVLMTrigger = "LiveStreamService: Triggering VLM Analysis at Frame \\(currentFrameIndex)\\n"
                        try? logVLMTrigger.data(using: .utf8)?.write(to: URL(fileURLWithPath: "/tmp/mb_log.txt"), options: .atomic) // Or rather append. Wait, safely append!
                        if let fh = try? FileHandle(forWritingTo: URL(fileURLWithPath: "/tmp/mb_log.txt")) { fh.seekToEndOfFile(); fh.write(logVLMTrigger.data(using: .utf8)!); try? fh.close() }
                        
                        let sessionBackup = sessionName
                        let indexBackup = currentFrameIndex
                        let iatMsBackup = iatMs
                        let boxesBackup = boundingBoxesJSON
                        let peakScoreBackup = peakMacroblockingScore
                        let tier = await MainActor.run { NativeVLMClient.shared.selectedTier }
                        let isVlmReady = await MainActor.run { 
                            if case .ready = NativeVLMClient.shared.state { return true }
                            return false 
                        }
                        
                        // We reached the sustained threshold. Call the VLM on the most severe frame so far.
                        if isVlmReady {
                            if let priorPath = getPreviousFrameHEIC(thumbnailsDir: thumbnailsDir), let peakPath = peakMacroblockingFramePath {
                                isStageAVerifying = true
                                Task(priority: .utility) {
                                    let isVerified = await NativeVLMClient.shared.analyzeStageA(lastGood: priorPath, bad: peakPath, tier: tier)
                                    await self.handleStageAResult(isVerified: isVerified,
                                                                  tierName: tier.displayName,
                                                                  peakPath: peakPath,
                                                                  peakScore: peakScoreBackup,
                                                                  boxes: boxesBackup,
                                                                  session: sessionBackup,
                                                                  index: indexBackup,
                                                                  iatMs: iatMsBackup)
                                }
                            }
                        } else {
                            // Offline fallback
                            isCurrentMBSeriesVerified = true
                            currentMBVerifiedEngine = "offline"
                            issuesFound.append(("macroblocking", peakMacroblockingScore, "offline", nil, boundingBoxesJSON))
                            let logVLMStatus = "LiveStreamService: VLM Offline, auto-approved\n"
                            if let fh = try? FileHandle(forWritingTo: URL(fileURLWithPath: "/tmp/mb_log.txt")) { fh.seekToEndOfFile(); fh.write(logVLMStatus.data(using: .utf8)!); try? fh.close() }
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
                            self.streamController?.enqueueVideoLog(
                                videoFilename: sessionBackup,
                                timestampSec: Double(indexBackup),
                                nodeSource: "VLM-Forensic",
                                nodeBackbone: "East-Backbone-Live",
                                nodeDest: "Incident Report",
                                issueType: "macroblocking_incident_summary",
                                issueScore: 1.0,
                                analysisEngine: tier.displayName,
                                thumbnailPath: URL(fileURLWithPath: peak).lastPathComponent,
                                issueSummary: summary,
                                iatMs: iatMs
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
                        self.streamController?.enqueueVideoLog(
                            videoFilename: sessionName,
                            timestampSec: Double(currentFrameIndex),
                            nodeSource: "Live-Multicast",
                            nodeBackbone: "East-Backbone-Live",
                            nodeDest: "Distribution-Node",
                            issueType: "ok",
                            issueScore: 1.0,
                            analysisEngine: defaultEngine,
                            thumbnailPath: nil,
                            iatMs: iatMs
                        )
                        lastOkLogTime = now
                    }
                }
            } else {
                recordIssueState()
                retainFileOnDisk = true
                
                for (issue, score, engine, summary, boxes) in issuesFound {
                    self.streamController?.enqueueVideoLog(
                        videoFilename: sessionName,
                        timestampSec: Double(currentFrameIndex),
                        nodeSource: "Live-Multicast",
                        nodeBackbone: "East-Backbone-Live",
                        nodeDest: "Distribution-Node",
                        issueType: issue,
                        issueScore: score,
                        analysisEngine: engine,
                        thumbnailPath: savedThumbPath != nil ? URL(fileURLWithPath: savedThumbPath!).lastPathComponent : nil,
                        issueSummary: summary,
                        iatMs: iatMs,
                        boundingBoxes: boxes
                    )
                }
            }
            
            if !retainFileOnDisk {
                try? FileManager.default.removeItem(at: thumbURL)
            }
            
            await ExtractionProgress.shared.set(status: "extracting", current: frameCount, total: 0, for: sessionName)
        }
    }
    
    // Removed updateVideoView and updateAudioView methods
    
    private func handleStageAResult(isVerified: Bool, tierName: String, peakPath: String, peakScore: Double, boxes: String?, session: String, index: Int, iatMs: Double) async {
        self.isStageAVerifying = false
        if isVerified {
            self.isCurrentMBSeriesVerified = true
            self.currentMBVerifiedEngine = tierName
            let logVLMStatus = "LiveStreamService: VLM APPROVED Incident\n"
            if let fh = try? FileHandle(forWritingTo: URL(fileURLWithPath: "/tmp/mb_log.txt")) { fh.seekToEndOfFile(); fh.write(logVLMStatus.data(using: .utf8)!); try? fh.close() }
            
            self.streamController?.enqueueVideoLog(
                videoFilename: session,
                timestampSec: Double(index),
                nodeSource: "Live-Multicast",
                nodeBackbone: "East-Backbone-Live",
                nodeDest: "Distribution-Node",
                issueType: "macroblocking",
                issueScore: peakScore,
                analysisEngine: tierName,
                thumbnailPath: URL(fileURLWithPath: peakPath).lastPathComponent,
                issueSummary: nil,
                iatMs: iatMs,
                boundingBoxes: boxes
            )
        } else {
            self.consecutiveMBCount = 0
            self.startOfIncidentPath = nil
            self.peakMacroblockingFramePath = nil
            appLogger.info("LLM rejected live macroblocking detection. Incident dropped.")
            let logVLMStatus = "LiveStreamService: VLM REJECTED Incident\n"
            if let fh = try? FileHandle(forWritingTo: URL(fileURLWithPath: "/tmp/mb_log.txt")) { fh.seekToEndOfFile(); fh.write(logVLMStatus.data(using: .utf8)!); try? fh.close() }
        }
    }
    
    static func determineDefaultEngine(isVlmReady: Bool, frameIndex: Int, tierName: String) -> String {
        return (isVlmReady && frameIndex % 5 == 0) ? tierName : "opencv"
    }
    
#if DEBUG
    // MARK: - Test Infrastructure
    func _injectFrameForTest(pixelBuffer: CVPixelBuffer, audioHealth: AudioHealth, networkIAT: Double, sessionName: String, thumbnailsDir: URL) async {
        await processFrame(pixelBuffer: pixelBuffer, audioHealth: audioHealth, networkIAT: networkIAT, sessionName: sessionName, thumbnailsDir: thumbnailsDir)
    }
    
    func _getAudioLossStartTime() -> TimeInterval? {
        return audioLossStartTime
    }
    
    func _getWasAudioHealthy() -> Bool? {
        return wasAudioHealthy
    }
    
    func _setLastOkLogTime(_ time: TimeInterval) {
        self.lastOkLogTime = time
    }
    
    func _setLastIssueEncounteredTime(_ time: TimeInterval) {
        self.lastIssueEncounteredTime = time
    }
#endif
}
