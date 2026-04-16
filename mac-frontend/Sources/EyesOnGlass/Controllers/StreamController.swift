import SwiftData
import Foundation
import SwiftUI
import Combine
import CoreVideo

/// The primary bridge between the background hardware Actors and the SwiftUI Views.
@Observable
@MainActor
final class StreamController: Identifiable, Hashable {
    let id = UUID()
    private(set) var liveStreamService: LiveStreamService!
    private let hardwareMonitor = HardwareMonitor()
    private let bitrateCalculator = BitrateCalculator()
    private var repository: VideoLogRepository?

    nonisolated static func == (lhs: StreamController, rhs: StreamController) -> Bool {
        lhs.id == rhs.id
    }

    nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    var activeSessionName: String?
    var connectionStatus: String = "Disconnected"
    var hardwareCPU: Double = 0.0
    var hardwareMemory: Double = 0.0
    var hardwareGPU: Double = 0.0
    var selectedTimeframe: String = "1m"
    var currentSessionIdentifier: String?
    var currentSessionStartTime: Date?

    @ObservationIgnored nonisolated let videoFrameSubject = PassthroughSubject<CVPixelBuffer, Never>()

    var metadata = StreamMetadata()

    // UI Proxy Properties for backward compatibility with Views
    var videoPID: UInt16? { metadata.videoPID }
    var audioPID: UInt16? { metadata.audioPID }
    var videoResolution: CGSize? { metadata.videoResolution }
    var videoColor: String? { metadata.videoColor }
    var videoGOPSize: Int? { metadata.videoGOPSize }
    var videoFrameRate: Double? { metadata.videoFrameRate }
    var audioSampleRate: Int? { metadata.audioSampleRate }
    var audioChannels: Int? { metadata.audioChannels }
    var audioCodec: String? { metadata.audioCodec }
    var audioBitrate: Double? { metadata.audioBitrate }
    var audioLoudness: Double? { metadata.audioLoudness }
    var audioTruePeak: Double? { metadata.audioTruePeak }
    var audioDialNorm: Int? { metadata.audioDialNorm }

    var tsID: UInt16? { metadata.tsID }
    var programID: UInt16? { metadata.programID }
    var servicesCount: Int { metadata.servicesCount }
    var sdtChannel: String? { metadata.sdtChannel }
    var sdtProvider: String? { metadata.sdtProvider }
    var tsClock: String? { metadata.tsClock }
    var pcrJitter: Double? { metadata.pcrJitter }
    var pcrInterval: Double? { metadata.pcrInterval }
    
    var videoAspect: String? {
        guard let res = metadata.videoResolution else { return nil }
        let w = Int(res.width)
        let h = Int(res.height)
        if (w == 1920 && h == 1080) || (w == 1280 && h == 720) || (w == 3840 && h == 2160) { return "16:9" }
        if w == 720 && h == 480 { return "4:3" }
        return "\(w):\(h)"
    }
    
    var streamIP: String = "-"
    var streamPort: String = "-"
    var streamSourceType: String = "-"
    
    var currentIAT: Double? = nil
    
    var streamDuration: TimeInterval = 0
    var streamPackets: Int = 0
    var streamFramesAnalyzed: Int = 0
    var streamBitrate: Double = 0.0
    var streamCCErrors: Int = 0
    var totalCCErrors: Int = 0
    var hardwareStatsHistory: [SystemMonitor.StatPoint] = []
    
    var audioWaveformData: [Float] = []
    var audioVectorscopeData: [CGPoint] = []
    var audioPhaseData: [Float] = []
    var audioLevelsData: [Float] = []
    
    var isAdvancedInspectorVisible: Bool = false
    var isVBR: Bool = false
    private var lastPacketsValue: Int = 0
    private var lastCheckTime: Date? = nil
    
    private(set) var isMuted: Bool = true
    
    func toggleMute() {
        isMuted.toggle()
        let muteState = isMuted
        Task {
            await self.liveStreamService.setMuted(muteState)
        }
    }
    
    // Injected SwiftData context for the background extraction engine to utilize
    var modelContext: ModelContext? {
        didSet {
            if let context = modelContext {
                self.repository = VideoLogRepository(context: context)
            }
        }
    }
    
    init() {
        self.liveStreamService = LiveStreamService(streamController: self)

        Task {
            await SystemMonitor.shared.start()
            while true {
                let currentFrame = self.selectedTimeframe
                let sessionID = self.currentSessionIdentifier
                let startTime = self.currentSessionStartTime
                
                let stats = await self.hardwareMonitor.update(selectedTimeframe: currentFrame)

                // Fetch progress asynchronously outside MainActor
                let allProgress = await ExtractionProgress.shared.all()
                let progress = sessionID.flatMap { allProgress[$0] }
                
                let info = await self.liveStreamService.getStreamInfo()
                
                await MainActor.run {
                    self.updateMetadata(from: info)
                    
                    self.hardwareCPU = stats.cpu
                    self.hardwareMemory = stats.memory
                    self.hardwareGPU = stats.gpu
                    self.hardwareStatsHistory = stats.history
                    
                    if let start = startTime {
                        self.updateSessionMetrics(start: start, progress: progress)
                    } else {
                        self.resetSessionMetrics()
                    }
                }
                
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }
    
    private func updateMetadata(from info: (videoPID: UInt16?, audioPID: UInt16?, resolution: CGSize?, audioSampleRate: Int?, audioChannels: Int?, audioCodec: String?, audioBitrate: Double?, audioLoudness: Double?, audioTruePeak: Double?, audioDialNorm: Int?, tsID: UInt16?, programID: UInt16?, servicesCount: Int, sdtChannel: String?, sdtProvider: String?, videoColor: String?, videoGOPSize: Int?, videoFrameRate: Double?, tsClock: String?, pcrJitter: Double?, pcrInterval: Double?)) {
        self.metadata.videoPID = info.videoPID
        self.metadata.audioPID = info.audioPID
        self.metadata.videoResolution = info.resolution
        self.metadata.audioSampleRate = info.audioSampleRate
        self.metadata.audioChannels = info.audioChannels
        self.metadata.audioCodec = info.audioCodec
        self.metadata.audioBitrate = info.audioBitrate
        self.metadata.audioLoudness = info.audioLoudness
        self.metadata.audioTruePeak = info.audioTruePeak
        self.metadata.audioDialNorm = info.audioDialNorm
        self.metadata.videoColor = info.videoColor
        self.metadata.videoGOPSize = info.videoGOPSize
        self.metadata.videoFrameRate = info.videoFrameRate

        self.metadata.tsID = info.tsID
        self.metadata.programID = info.programID
        self.metadata.servicesCount = info.servicesCount
        self.metadata.sdtChannel = info.sdtChannel
        self.metadata.sdtProvider = info.sdtProvider

        self.metadata.tsClock = info.tsClock
        self.metadata.pcrJitter = info.pcrJitter
        self.metadata.pcrInterval = info.pcrInterval
    }

    private func updateSessionMetrics(start: Date, progress: ExtractionProgress.ProgressInfo?) {
        if self.connectionStatus == "Active" {
            self.streamDuration = Date().timeIntervalSince(start)
        }
        if let prog = progress {
            let currentTotalPackets = prog.packets ?? 0
            let delta = currentTotalPackets - self.lastPacketsValue
            self.lastPacketsValue = currentTotalPackets
            self.streamPackets = currentTotalPackets
            self.streamFramesAnalyzed = prog.current

            let dur = max(self.streamDuration, 1.0)
            self.streamBitrate = Double(self.streamPackets) * 188.0 * 8.0 / dur / 1_000_000.0

            if self.streamDuration > 2.0 {
                let now = Date()
                let elapsed = self.lastCheckTime != nil ? now.timeIntervalSince(self.lastCheckTime!) : 2.0
                self.lastCheckTime = now

                if elapsed > 0.5 {
                    let bitrateState = self.bitrateCalculator.update(delta: delta, elapsed: elapsed)
                    self.isVBR = bitrateState.isVBR
                }
            }
        }
    }

    private func resetSessionMetrics() {
        self.streamDuration = 0
        self.streamPackets = 0
        self.streamFramesAnalyzed = 0
        self.streamBitrate = 0.0
        self.streamCCErrors = 0
        self.isVBR = false
        self.bitrateCalculator.reset()
        self.lastPacketsValue = 0
        self.lastCheckTime = nil
    }

    @MainActor
    func startMonitoring(uri: String, context: ModelContext) async {
        self.modelContext = context
        self.clearEvents()
        
        self.connectionStatus = "Connecting..."
        self.activeSessionName = uri
        
        let sessionIdentifier = "Live-\(uri)-\(Date().timeIntervalSince1970)"
        self.currentSessionIdentifier = sessionIdentifier
        self.currentSessionStartTime = Date()
        
        self.parseURI(uri)

        // Dispatch to the native actor to boot the hardware session
        await self.liveStreamService.startMonitoring(uri: uri, sessionName: sessionIdentifier)
        await self.liveStreamService.setMuted(self.isMuted)
        self.connectionStatus = "Active"
    }

    private func parseURI(_ uri: String) {
        var cleanURI = uri.replacingOccurrences(of: "udp://", with: "")
        cleanURI = cleanURI.replacingOccurrences(of: "@", with: "")
        let parts = cleanURI.split(separator: ":")
        if parts.count == 2 {
            self.streamIP = String(parts[0])
            self.streamPort = String(parts[1])
            self.streamSourceType = "UDP"
            if let p1 = Int(self.streamIP.split(separator: ".").first ?? "0"), p1 >= 224, p1 <= 239 {
                self.streamSourceType = "Multicast"
            }
        }
    }
    
    @MainActor
    func stopMonitoring() async {
        await self.liveStreamService.stopMonitoring()
        self.connectionStatus = "Disconnected"
        self.activeSessionName = nil
        
        self.audioWaveformData = []
        self.audioVectorscopeData = []
        self.audioPhaseData = []
        self.audioLevelsData = []
    }
    
    @MainActor
    func clearEvents() {
        self.repository?.archiveActiveLogs()

        self.currentSessionIdentifier = nil
        self.currentSessionStartTime = nil
        self.metadata = StreamMetadata()
        self.currentIAT = nil
        
        self.streamIP = "-"
        self.streamPort = "-"
        self.streamSourceType = "-"
        self.streamFramesAnalyzed = 0
        
        self.resetSessionMetrics()
    }
    
    @MainActor
    func incrementCCErrors() {
        self.streamCCErrors += 1
        self.totalCCErrors += 1
    }
    
    @MainActor
    func clearCCErrors() {
        self.streamCCErrors = 0
        self.totalCCErrors = 0
    }

    @MainActor
    func updateIAT(_ iat: Double) {
        self.currentIAT = iat
    }

    @MainActor
    func insertVideoLog(videoFilename: String, timestampSec: Double, nodeSource: String?, nodeBackbone: String?, nodeDest: String?, issueType: String, issueScore: Double?, analysisEngine: String?, thumbnailPath: String?, issueSummary: String? = nil, iatMs: Double? = nil, boundingBoxes: String? = nil) {
        self.repository?.insert(
            videoFilename: videoFilename,
            timestampSec: timestampSec,
            nodeSource: nodeSource,
            nodeBackbone: nodeBackbone,
            nodeDest: nodeDest,
            issueType: issueType,
            issueScore: issueScore,
            analysisEngine: analysisEngine,
            thumbnailPath: thumbnailPath,
            sessionIdentifier: currentSessionIdentifier,
            sessionStartTime: currentSessionStartTime,
            issueSummary: issueSummary,
            iatMs: iatMs,
            boundingBoxes: boundingBoxes
        )
    }
}
