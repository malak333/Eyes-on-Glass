import SwiftData
import Foundation
import CoreVideo
import CoreImage
import SwiftUI
import AppKit

actor LiveStreamService: VideoLogReporter {
    private weak var streamController: StreamController?
    private let visualsRenderer: UIVisualsRenderer
    
    // Strategy-based Detectors
    private let blackScreenDetector = BlackScreenDetector()
    private let macroblockingDetector = MacroblockingDetector()
    private let connectivityDetector = ConnectivityDetector()
    private let audioDetector = AudioAnomalyDetector()
    
    private var detectors: [any AnomalyDetector] {
        [blackScreenDetector, macroblockingDetector, connectivityDetector, audioDetector]
    }

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
    private var lastFrameProcessTime: TimeInterval = 0

    final class DropFrameState: @unchecked Sendable {
        private let lock = NSLock()
        var isBusy = false
        
        func tryAcquire() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if isBusy { return false }
            isBusy = true
            return true
        }
        
        func release() {
            lock.lock()
            isBusy = false
            lock.unlock()
        }
    }

    // Frame Dropout Backpressure State
    private let processingState = DropFrameState()
    
    private(set) var isStageAVerifying: Bool = false
    
    func setStageAVerifyingStatus(_ status: Bool) {
        self.isStageAVerifying = status
    }

    func incrementPendingCCErrors() {
        Task {
            await connectivityDetector.incrementCCErrors()
        }
    }
    
    func popPendingCCErrors() async -> Int {
        return await connectivityDetector.getAndResetCCErrors()
    }
    
    func recordIssueState() {
        lastIssueEncounteredTime = Date().timeIntervalSince1970
        isPendingRecovery = true
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
    
    func startMonitoring(uri: String, sessionName: String) async {
        if isActive {
            await stopMonitoring()
        }
        isActive = true
        activeSessionName = sessionName
        lastOkLogTime = 0 
        lastIssueEncounteredTime = Date().timeIntervalSince1970
        isPendingRecovery = true
        frameCount = 0
        lastFrameProcessTime = 0

        for detector in detectors {
            await detector.reset()
        }
        
        let thumbnailsDir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents/EyesOnGlass/thumbnails")
        try? FileManager.default.createDirectory(at: thumbnailsDir, withIntermediateDirectories: true)
        
        let newIngestor = UDPIngestor()
        self.ingestor = newIngestor
        
        Task(priority: .userInitiated) {
            await newIngestor.start(uri: uri, onFrame: { [weak self] pixelBuffer, audioHealth, networkIAT in
                guard let self = self else { return }
                
                Task {
                    let canProcess = await self.canProcessFrame()
                    if !canProcess {
                        appLogger.warning("LiveStreamService: Dropped frame due to Vision backlog backpressure.")
                        return
                    }

                    await self.processFrame(pixelBuffer: pixelBuffer, audioHealth: audioHealth, networkIAT: networkIAT, sessionName: sessionName, thumbnailsDir: thumbnailsDir)
                    await self.releaseFrame()
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
                    await self.connectivityDetector.incrementCCErrors()
                }
            }, onStreamLost: {
                Task(priority: .utility) {
                    await self.recordIssueState()
                    let ts = Double(await self.frameCount)
                    await self.streamController?.enqueueVideoLog(
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
                    await self.recordIssueState()
                    let ts = Double(await self.frameCount)
                    await self.streamController?.enqueueVideoLog(
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
                    await self.recordIssueState()
                    let ts = Double(await self.frameCount)
                    await self.streamController?.enqueueVideoLog(
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
                    await self.recordIssueState()
                    let ts = Double(await self.frameCount)
                    await self.streamController?.enqueueVideoLog(
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
    
    private func canProcessFrame() -> Bool {
        return processingState.tryAcquire()
    }

    private func releaseFrame() {
        processingState.release()
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
        
        let iatMs = networkIAT
        lastFrameProcessTime = CFAbsoluteTimeGetCurrent()
        
        let localController = self.streamController
        Task { @MainActor [localController] in
            localController?.updateIAT(iatMs)
        }
        
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let cvResults = VisionAnalyzer.analyze(ciImage: ciImage, context: ciContext)
        
        // Performance Optimization: Compress once and pass to detectors
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return }
        let heicData = ciContext.heifRepresentation(of: ciImage, format: .RGBA8, colorSpace: colorSpace, options: [:])

        var combinedIssues: [DetectedIssue] = []
        for detector in detectors {
            let issues = await detector.detectAnomalies(
                pixelBuffer: pixelBuffer,
                ciImage: ciImage,
                cvResults: cvResults,
                audioHealth: audioHealth,
                networkIAT: networkIAT,
                sessionName: sessionName,
                frameIndex: currentFrameIndex,
                thumbnailsDir: thumbnailsDir,
                reporter: self,
                heicData: heicData
            )
            combinedIssues.append(contentsOf: issues)
        }
        
        if combinedIssues.isEmpty {
            let tier = await MainActor.run { NativeVLMClient.shared.selectedTier }
            let isVlmReady = await MainActor.run {
                if case .ready = NativeVLMClient.shared.state { return true }
                return false
            }
            let defaultEngine = LiveStreamService.determineDefaultEngine(isVlmReady: isVlmReady, frameIndex: currentFrameIndex, tierName: tier.displayName)
            
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
        } else {
            recordIssueState()
            for issue in combinedIssues {
                self.streamController?.enqueueVideoLog(
                    videoFilename: sessionName,
                    timestampSec: Double(currentFrameIndex),
                    nodeSource: issue.customNodeSource ?? "Live-Multicast",
                    nodeBackbone: issue.customNodeBackbone ?? "East-Backbone-Live",
                    nodeDest: issue.customNodeDest ?? "Distribution-Node",
                    issueType: issue.type,
                    issueScore: issue.score,
                    analysisEngine: issue.engine,
                    thumbnailPath: issue.thumbnailPath,
                    issueSummary: issue.summary,
                    iatMs: iatMs,
                    boundingBoxes: issue.boundingBoxes
                )
            }
        }

        await ExtractionProgress.shared.set(status: "extracting", current: frameCount, total: 0, for: sessionName)
    }
    
    // VideoLogReporter Implementation
    nonisolated func enqueueVideoLog(
        type: String,
        score: Double,
        engine: String,
        summary: String?,
        boundingBoxes: String?,
        thumbnailPath: String?,
        nodeSource: String?,
        nodeBackbone: String?,
        nodeDest: String?
    ) {
        Task { [weak self] in
            guard let self = self else { return }
            let session = await self.activeSessionName ?? "unknown"
            let index = await self.frameCount
            
            await self.streamController?.enqueueVideoLog(
                videoFilename: session,
                timestampSec: Double(index),
                nodeSource: nodeSource ?? "Live-Multicast",
                nodeBackbone: nodeBackbone ?? "East-Backbone-Live",
                nodeDest: nodeDest ?? "Distribution-Node",
                issueType: type,
                issueScore: score,
                analysisEngine: engine,
                thumbnailPath: thumbnailPath,
                issueSummary: summary,
                iatMs: nil,
                boundingBoxes: boundingBoxes
            )
        }
    }
    
    static func determineDefaultEngine(isVlmReady: Bool, frameIndex: Int, tierName: String) -> String {
        return (isVlmReady && frameIndex % 5 == 0) ? tierName : "opencv"
    }
    
#if DEBUG
    func _injectFrameForTest(pixelBuffer: CVPixelBuffer, audioHealth: AudioHealth, networkIAT: Double, sessionName: String, thumbnailsDir: URL) async {
        await processFrame(pixelBuffer: pixelBuffer, audioHealth: audioHealth, networkIAT: networkIAT, sessionName: sessionName, thumbnailsDir: thumbnailsDir)
    }
#endif
}
