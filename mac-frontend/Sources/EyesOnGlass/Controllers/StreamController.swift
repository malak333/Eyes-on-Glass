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
    
    // Injected SwiftData context for the background extraction engine to utilize
    var modelContext: ModelContext?
    
    init() {
        Task {
            await SystemMonitor.shared.start()
            while true {
                let stats = await SystemMonitor.shared.getAggregatedStats()
                // Use local copy of selectedTimeframe to ensure thread safety
                let currentFrame = self.selectedTimeframe
                if let windowStats = stats[currentFrame], !windowStats.isEmpty {
                    let avgCpu = windowStats.reduce(0.0) { $0 + $1.cpu } / Double(windowStats.count)
                    let avgMem = windowStats.reduce(0.0) { $0 + $1.memory } / Double(windowStats.count)
                    let avgGpu = windowStats.reduce(0.0) { $0 + $1.gpu } / Double(windowStats.count)
                    
                    await MainActor.run {
                        self.hardwareCPU = avgCpu
                        self.hardwareMemory = avgMem
                        self.hardwareGPU = avgGpu
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
        
        // Dispatch to the native actor to boot the hardware session
        await LiveStreamService.shared.startMonitoring(uri: uri, sessionName: sessionIdentifier)
        self.connectionStatus = "Active"
    }
    
    @MainActor
    func stopMonitoring() async {
        await LiveStreamService.shared.stopMonitoring()
        self.connectionStatus = "Disconnected"
        self.activeSessionName = nil
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
            thumbnailPath: thumbnailPath
        )
        context.insert(log)
    }
}
