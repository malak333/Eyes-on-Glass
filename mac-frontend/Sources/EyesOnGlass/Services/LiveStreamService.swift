import SwiftData
import Foundation
import CoreVideo
import CoreImage
import SwiftUI
import AppKit

class UIVisualsRenderer: @unchecked Sendable {
    private weak var streamController: StreamController?

    init(streamController: StreamController?) {
        self.streamController = streamController
    }

    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let videoQueue = DispatchQueue(label: "com.eyesonGlass.uiVideoRenderer")
    private let audioQueue = DispatchQueue(label: "com.eyesonGlass.uiAudioRenderer")
    
    private var lastAudioRenderTime: TimeInterval = 0
    private var isRenderingAudio = false

    func render(pixelBuffer: CVPixelBuffer) {
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
    private let ciContext = CIContext(options: [.cacheIntermediates: false])

    private var ingestor: UDPIngestor?
    private var isActive = false
    private var activeSessionName: String?
    private var frameCount: Int = 0

    // Detectors
    private var blackScreenDetector: BlackScreenDetector
    private var macroblockingDetector: MacroblockingDetector
    private var connectivityDetector = ConnectivityDetector()

    // State
    private var lastOkLogTime: TimeInterval = 0
    private var lastIssueEncounteredTime: TimeInterval = 0
    private var isPendingRecovery: Bool = true
    private var visualRingBuffer: [Data] = []
    private var audioLossStartTime: TimeInterval? = nil
    private var wasAudioHealthy: Bool? = nil

    init(streamController: StreamController?) {
        self.streamController = streamController
        self.visualsRenderer = UIVisualsRenderer(streamController: streamController)
        self.blackScreenDetector = BlackScreenDetector(streamController: streamController)
        self.macroblockingDetector = MacroblockingDetector(streamController: streamController)
    }

    func incrementPendingCCErrors() {
        connectivityDetector.incrementPendingCCErrors()
    }
    
    func recordIssueState() {
        lastIssueEncounteredTime = Date().timeIntervalSince1970
        isPendingRecovery = true
    }
    
    func getStreamInfo() async -> (videoPID: UInt16?, audioPID: UInt16?, resolution: CGSize?, audioSampleRate: Int?, audioChannels: Int?, audioCodec: String?, audioBitrate: Double?, audioLoudness: Double?, audioTruePeak: Double?, audioDialNorm: Int?, tsID: UInt16?, programID: UInt16?, servicesCount: Int, sdtChannel: String?, sdtProvider: String?, videoColor: String?, videoGOPSize: Int?, videoFrameRate: Double?, tsClock: String?, pcrJitter: Double?, pcrInterval: Double?) {
        if let ingestor = ingestor {
            return await ingestor.streamInfo
        }
        return (nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, 0, nil, nil, nil, nil, nil, nil, nil, nil)
    }
    
    func startMonitoring(uri: String, sessionName: String) async {
        if isActive { await stopMonitoring() }
        isActive = true
        activeSessionName = sessionName
        resetInternalState()
        
        let thumbnailsDir = getThumbnailsDir()
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
                Task(priority: .utility) { await ExtractionProgress.shared.setPackets(count, for: sessionName) }
            }, onCCError: {
                Task(priority: .utility) {
                    self.incrementPendingCCErrors()
                    await MainActor.run { self.streamController?.incrementCCErrors() }
                }
            }, onStreamLost: { await self.logIngestorIssue(sessionName: sessionName, type: "stream_lost") },
            onStreamRestored: { await self.logIngestorIssue(sessionName: sessionName, type: "stream_restored") },
            onVideoLost: { await self.logIngestorIssue(sessionName: sessionName, type: "video_lost") },
            onVideoRestored: { await self.logIngestorIssue(sessionName: sessionName, type: "video_restored") })
        }
    }

    private func resetInternalState() {
        lastOkLogTime = 0
        lastIssueEncounteredTime = Date().timeIntervalSince1970
        isPendingRecovery = true
        frameCount = 0
        wasAudioHealthy = nil
        audioLossStartTime = nil
        visualRingBuffer.removeAll()
        blackScreenDetector = BlackScreenDetector(streamController: streamController)
        macroblockingDetector = MacroblockingDetector(streamController: streamController)
        connectivityDetector = ConnectivityDetector()
    }

    private func getThumbnailsDir() -> URL {
        let dir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents/EyesOnGlass/thumbnails")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func logIngestorIssue(sessionName: String, type: String) async {
        Task(priority: .utility) {
            self.recordIssueState()
            await self.streamController?.insertVideoLog(
                videoFilename: sessionName,
                timestampSec: Double(self.frameCount),
                nodeSource: "Live-Multicast",
                nodeBackbone: "East-Backbone-Live",
                nodeDest: "Distribution-Node",
                issueType: type,
                issueScore: 1.0,
                analysisEngine: "ingestor",
                thumbnailPath: nil
            )
        }
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
        
        await MainActor.run { streamController?.updateIAT(networkIAT) }
        
        let isAudioHealthy = (audioHealth == .healthy)
        await handleAudioHealth(isAudioHealthy: isAudioHealthy, sessionName: sessionName, frameIndex: currentFrameIndex, iatMs: networkIAT)
        
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return }
        let encodedFrame = ciContext.heifRepresentation(of: ciImage, format: .RGBA8, colorSpace: colorSpace, options: [:])
        
        updateRingBuffer(encodedFrame: encodedFrame)

        let cvResults = VisionAnalyzer.analyze(ciImage: ciImage, context: ciContext)
        
        var anomalies: [Anomaly] = []
        anomalies += await connectivityDetector.analyze(pixelBuffer: pixelBuffer, encodedFrame: encodedFrame, cvResults: cvResults, now: now, frameCount: currentFrameIndex, thumbnailsDir: thumbnailsDir, visualRingBuffer: visualRingBuffer)
        anomalies += await blackScreenDetector.analyze(pixelBuffer: pixelBuffer, encodedFrame: encodedFrame, cvResults: cvResults, now: now, frameCount: currentFrameIndex, thumbnailsDir: thumbnailsDir, visualRingBuffer: visualRingBuffer)
        anomalies += await macroblockingDetector.analyze(pixelBuffer: pixelBuffer, encodedFrame: encodedFrame, cvResults: cvResults, now: now, frameCount: currentFrameIndex, thumbnailsDir: thumbnailsDir, visualRingBuffer: visualRingBuffer)

        if networkIAT > 40.0 {
            anomalies.append(Anomaly(type: "high_iat", score: 1.0, engine: "ingestor", summary: String(format: "IAT spiked to %.1f ms", networkIAT), boundingBoxes: nil))
        }

        if anomalies.isEmpty {
            await handleHealthyState(sessionName: sessionName, frameIndex: currentFrameIndex, iatMs: networkIAT, now: now)
        } else {
            await handleAnomalyState(anomalies: anomalies, sessionName: sessionName, frameIndex: currentFrameIndex, iatMs: networkIAT, thumbnailsDir: thumbnailsDir, encodedFrame: encodedFrame)
        }

        await ExtractionProgress.shared.set(status: "extracting", current: frameCount, total: 0, for: sessionName)
    }

    private func handleAudioHealth(isAudioHealthy: Bool, sessionName: String, frameIndex: Int, iatMs: Double) async {
        let nowTime = CFAbsoluteTimeGetCurrent()
        if isAudioHealthy {
            audioLossStartTime = nil
            if wasAudioHealthy == false {
                recordIssueState()
                await streamController?.insertVideoLog(videoFilename: sessionName, timestampSec: Double(frameIndex), nodeSource: "Live-Multicast", nodeBackbone: "East-Backbone-Live", nodeDest: "Distribution-Node", issueType: "audio_restored", issueScore: 1.0, analysisEngine: "ingestor", thumbnailPath: nil, iatMs: iatMs)
            }
            wasAudioHealthy = true
        } else {
            if audioLossStartTime == nil { audioLossStartTime = nowTime }
            if nowTime - (audioLossStartTime ?? nowTime) >= 2.0 {
                if wasAudioHealthy == true {
                    recordIssueState()
                    await streamController?.insertVideoLog(videoFilename: sessionName, timestampSec: Double(frameIndex), nodeSource: "Live-Multicast", nodeBackbone: "East-Backbone-Live", nodeDest: "Distribution-Node", issueType: "audio_lost", issueScore: 1.0, analysisEngine: "ingestor", thumbnailPath: nil)
                }
                wasAudioHealthy = false
            }
        }
    }

    private func updateRingBuffer(encodedFrame: Data?) {
        guard let data = encodedFrame else { return }
        visualRingBuffer.append(data)
        if visualRingBuffer.count > 30 { visualRingBuffer.removeFirst() }
    }

    private func handleHealthyState(sessionName: String, frameIndex: Int, iatMs: Double, now: TimeInterval) async {
        guard wasAudioHealthy == true else { return }
        let timeSinceLastIssue = now - lastIssueEncounteredTime
        var shouldLogOk = false
        
        if isPendingRecovery {
            if timeSinceLastIssue >= 3.0 {
                shouldLogOk = true
                isPendingRecovery = false
            }
        } else if now - lastOkLogTime >= 600.0 {
            shouldLogOk = true
        }
        
        if shouldLogOk {
            let tier = await MainActor.run { NativeVLMClient.shared.selectedTier }
            let isVlmReady = await MainActor.run { if case .ready = NativeVLMClient.shared.state { return true }; return false }
            let engine = (isVlmReady && frameIndex % 5 == 0) ? tier.displayName : "opencv"
            
            await streamController?.insertVideoLog(videoFilename: sessionName, timestampSec: Double(frameIndex), nodeSource: "Live-Multicast", nodeBackbone: "East-Backbone-Live", nodeDest: "Distribution-Node", issueType: "ok", issueScore: 1.0, analysisEngine: engine, thumbnailPath: nil, iatMs: iatMs)
            lastOkLogTime = now
        }
    }
    
    private func handleAnomalyState(anomalies: [Anomaly], sessionName: String, frameIndex: Int, iatMs: Double, thumbnailsDir: URL, encodedFrame: Data?) async {
        recordIssueState()
        let thumbPath = saveFrameToDisk(data: encodedFrame, thumbnailsDir: thumbnailsDir)

        for anomaly in anomalies {
            await streamController?.insertVideoLog(
                videoFilename: sessionName,
                timestampSec: Double(frameIndex),
                nodeSource: "Live-Multicast",
                nodeBackbone: "East-Backbone-Live",
                nodeDest: "Distribution-Node",
                issueType: anomaly.type,
                issueScore: anomaly.score,
                analysisEngine: anomaly.engine,
                thumbnailPath: thumbPath.flatMap { URL(fileURLWithPath: $0).lastPathComponent },
                issueSummary: anomaly.summary,
                iatMs: iatMs,
                boundingBoxes: anomaly.boundingBoxes
            )
        }
    }
    
    private func saveFrameToDisk(data: Data?, thumbnailsDir: URL) -> String? {
        guard let data = data else { return nil }
        let url = thumbnailsDir.appendingPathComponent("live_\(UUID().uuidString).heic")
        try? data.write(to: url)
        return url.path
    }
}
