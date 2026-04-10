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
    
    var streamDuration: TimeInterval = 0
    var streamPackets: Int = 0
    var streamBitrate: Double = 0.0
    var streamCCErrors: Int = 0
    var totalCCErrors: Int = 0
    var hardwareStatsHistory: [SystemMonitor.StatPoint] = []
    
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
                
                await MainActor.run {
                    self.hardwareCPU = avgCpu
                    self.hardwareMemory = avgMem
                    self.hardwareGPU = avgGpu
                    self.hardwareStatsHistory = stats[currentFrame] ?? []
                    
                    if let start = startTime {
                        self.streamDuration = Date().timeIntervalSince(start)
                        if let prog = progress {
                            self.streamPackets = prog.packets ?? 0
                            let dur = max(self.streamDuration, 1.0)
                            self.streamBitrate = Double(self.streamPackets) * 1316.0 * 8.0 / dur / 1_000_000.0
                        }
                    } else {
                        self.streamDuration = 0
                        self.streamPackets = 0
                        self.streamBitrate = 0.0
                        self.streamCCErrors = 0
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
        
        // Dispatch to the native actor to boot the hardware session
        await LiveStreamService.shared.startMonitoring(uri: uri, sessionName: sessionIdentifier)
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
    }
    
    @MainActor
    func incrementCCErrors() {
        self.streamCCErrors += 1
        self.totalCCErrors += 1
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
