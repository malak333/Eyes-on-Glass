import SwiftData
import Foundation
import SwiftUI

/// The primary bridge between the background hardware Actors and the SwiftUI Views.
@Observable
@MainActor
final class StreamController {
    static let shared = StreamController()
    var activeSessionName: String?
    var connectionStatus: String = "Disconnected"
    var hardwareCPU: Double = 0.0
    var hardwareMemory: Double = 0.0
    var hardwareGPU: Double = 0.0
    var selectedTimeframe: String = "1m"
    var currentSessionIdentifier: String?
    var currentSessionStartTime: Date?
    var currentFrameImage: Image?

    var videoPID: UInt16? = nil
    var audioPID: UInt16? = nil
    var videoResolution: CGSize? = nil
    var videoColor: String? = nil
    var videoGOPSize: Int? = nil
    var videoFrameRate: Double? = nil
    var audioSampleRate: Int? = nil
    var audioChannels: Int? = nil
    var audioCodec: String? = nil
    var audioBitrate: Double? = nil
    var audioLoudness: Double? = nil
    var audioTruePeak: Double? = nil
    var audioDialNorm: Int? = nil
    
    var videoAspect: String? {
        guard let res = videoResolution else { return nil }
        let w = Int(res.width)
        let h = Int(res.height)
        if (w == 1920 && h == 1080) || (w == 1280 && h == 720) || (w == 3840 && h == 2160) { return "16:9" }
        if w == 720 && h == 480 { return "4:3" }
        return "\(w):\(h)"
    }
    
    var streamIP: String = "-"
    var streamPort: String = "-"
    var streamSourceType: String = "-"
    
    var tsID: UInt16? = nil
    var programID: UInt16? = nil
    var servicesCount: Int = 0
    var sdtChannel: String? = nil
    var sdtProvider: String? = nil
    
    // PCR metrics
    var tsClock: String? = nil
    var pcrJitter: Double? = nil
    var pcrInterval: Double? = nil
    
    var streamDuration: TimeInterval = 0
    var streamPackets: Int = 0
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
    private var bitrateHistory: [Double] = []
    private var lastPacketsValue: Int = 0
    
    private(set) var isMuted: Bool = true
    
    func toggleMute() {
        isMuted.toggle()
        let muteState = isMuted
        Task {
            await LiveStreamService.shared.setMuted(muteState)
        }
    }
    
    // Injected SwiftData context for the background extraction engine to utilize
    var modelContext: ModelContext?
    
    init() {
        Task {
            await SystemMonitor.shared.start()
            while true {
                let stats = await SystemMonitor.shared.getAggregatedStats()
                // Use local copy of selectedTimeframe to ensure thread safety
                let currentFrame = self.selectedTimeframe
                let sessionID = self.currentSessionIdentifier
                let startTime = self.currentSessionStartTime
                
                // Fetch stats asynchronously outside MainActor
                let allProgress = await ExtractionProgress.shared.all()
                let progress = sessionID.flatMap { allProgress[$0] }
                
                var avgCpu = 0.0, avgMem = 0.0, avgGpu = 0.0
                if let windowStats = stats[currentFrame], !windowStats.isEmpty {
                    avgCpu = windowStats.reduce(0.0) { $0 + $1.cpu } / Double(windowStats.count)
                    avgMem = windowStats.reduce(0.0) { $0 + $1.memory } / Double(windowStats.count)
                    avgGpu = windowStats.reduce(0.0) { $0 + $1.gpu } / Double(windowStats.count)
                }
                
                let info = await LiveStreamService.shared.getStreamInfo()
                
                await MainActor.run {
                    self.videoPID = info.videoPID
                    self.audioPID = info.audioPID
                    self.videoResolution = info.resolution
                    self.audioSampleRate = info.audioSampleRate
                    self.audioChannels = info.audioChannels
                    self.audioCodec = info.audioCodec
                    self.audioBitrate = info.audioBitrate
                    self.audioLoudness = info.audioLoudness
                    self.audioTruePeak = info.audioTruePeak
                    self.audioDialNorm = info.audioDialNorm
                    self.videoColor = info.videoColor
                    self.videoGOPSize = info.videoGOPSize
                    self.videoFrameRate = info.videoFrameRate
                    
                    self.tsID = info.tsID
                    self.programID = info.programID
                    self.servicesCount = info.servicesCount
                    self.sdtChannel = info.sdtChannel
                    self.sdtProvider = info.sdtProvider
                    
                    self.tsClock = info.tsClock
                    self.pcrJitter = info.pcrJitter
                    self.pcrInterval = info.pcrInterval
                    
                    self.hardwareCPU = avgCpu
                    self.hardwareMemory = avgMem
                    self.hardwareGPU = avgGpu
                    self.hardwareStatsHistory = stats[currentFrame] ?? []
                    
                    if let start = startTime {
                        self.streamDuration = Date().timeIntervalSince(start)
                        if let prog = progress {
                            let currentTotalPackets = prog.packets ?? 0
                            let delta = currentTotalPackets - self.lastPacketsValue
                            self.lastPacketsValue = currentTotalPackets
                            self.streamPackets = currentTotalPackets
                            
                            let dur = max(self.streamDuration, 1.0)
                            self.streamBitrate = Double(self.streamPackets) * 1316.0 * 8.0 / dur / 1_000_000.0
                            
                            if self.streamDuration > 2.0 {
                                let instBitrate = Double(delta) * 1316.0 * 8.0 / 2.0 / 1_000_000.0
                                if instBitrate > 0.1 {
                                    self.bitrateHistory.append(instBitrate)
                                    if self.bitrateHistory.count > 10 {
                                        self.bitrateHistory.removeFirst()
                                    }
                                    if self.bitrateHistory.count >= 5 {
                                        let maxB = self.bitrateHistory.max() ?? 0
                                        let minB = self.bitrateHistory.min() ?? 0
                                        if maxB > 0 && ((maxB - minB) / maxB > 0.10) {
                                            self.isVBR = true
                                        } else {
                                            self.isVBR = false
                                        }
                                    }
                                }
                            }
                        }
                    } else {
                        self.streamDuration = 0
                        self.streamPackets = 0
                        self.streamBitrate = 0.0
                        self.streamCCErrors = 0
                        self.isVBR = false
                        self.bitrateHistory.removeAll()
                        self.lastPacketsValue = 0
                    }
                }
                
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }
    
    @MainActor
    func startMonitoring(uri: String, context: ModelContext) async {
        self.modelContext = context
        self.connectionStatus = "Connecting..."
        self.activeSessionName = uri
        
        let sessionIdentifier = "Live-\(uri)-\(Date().timeIntervalSince1970)"
        self.currentSessionIdentifier = sessionIdentifier
        self.currentSessionStartTime = Date()
        self.streamCCErrors = 0
        
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
        
        // Dispatch to the native actor to boot the hardware session
        await LiveStreamService.shared.startMonitoring(uri: uri, sessionName: sessionIdentifier)
        await LiveStreamService.shared.setMuted(self.isMuted)
        self.connectionStatus = "Active"
    }
    
    @MainActor
    func stopMonitoring() async {
        await LiveStreamService.shared.stopMonitoring()
        self.connectionStatus = "Disconnected"
        self.activeSessionName = nil
        
        if let context = self.modelContext {
            let descriptor = FetchDescriptor<VideoLog>(predicate: #Predicate { $0.isArchived == false })
            if let activeLogs = try? context.fetch(descriptor) {
                for log in activeLogs {
                    log.isArchived = true
                }
                try? context.save()
            }
        }
        self.currentSessionIdentifier = nil
        self.currentSessionStartTime = nil
        self.currentFrameImage = nil
        self.videoPID = nil
        self.audioPID = nil
        self.videoResolution = nil
        self.videoColor = nil
        self.videoGOPSize = nil
        self.videoFrameRate = nil
        self.audioSampleRate = nil
        self.audioChannels = nil
        self.audioCodec = nil
        self.audioBitrate = nil
        self.audioLoudness = nil
        self.audioTruePeak = nil
        self.audioDialNorm = nil
        
        self.tsID = nil
        self.programID = nil
        self.servicesCount = 0
        self.sdtChannel = nil
        self.sdtProvider = nil
        
        self.tsClock = nil
        self.pcrJitter = nil
        self.pcrInterval = nil
        
        self.streamIP = "-"
        self.streamPort = "-"
        self.streamSourceType = "-"
        
        self.isVBR = false
        self.bitrateHistory.removeAll()
        self.lastPacketsValue = 0
        
        self.audioWaveformData = []
        self.audioVectorscopeData = []
        self.audioPhaseData = []
        self.audioLevelsData = []
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
    func insertVideoLog(videoFilename: String, timestampSec: Double, nodeSource: String?, nodeBackbone: String?, nodeDest: String?, issueType: String, issueScore: Double?, analysisEngine: String?, thumbnailPath: String?) {
        guard let context = self.modelContext else { return }
        let log = VideoLog(
            videoFilename: videoFilename,
            timestampSec: timestampSec,
            nodeSource: nodeSource,
            nodeBackbone: nodeBackbone,
            nodeDest: nodeDest,
            issueType: issueType,
            issueScore: issueScore,
            analysisEngine: analysisEngine,
            thumbnailPath: thumbnailPath,
            isArchived: false,
            sessionIdentifier: currentSessionIdentifier,
            sessionStartTime: currentSessionStartTime
        )
        context.insert(log)
    }
}
