import Foundation

struct StatPoint: Codable, Sendable {
    let cpu: Double
    let memory: Double
    let gpu: Double
    let timestamp: Date
}

actor HardwareMonitor {
    private var stats: [String: [StatPoint]] = [:]

    func update(selectedTimeframe: String) async -> (cpu: Double, memory: Double, gpu: Double, history: [StatPoint]) {
        let allStats = await SystemMonitor.shared.getAggregatedStats()
        self.stats = allStats

        var avgCpu = 0.0, avgMem = 0.0, avgGpu = 0.0
        let windowStats = allStats[selectedTimeframe] ?? []

        if !windowStats.isEmpty {
            avgCpu = windowStats.reduce(0.0) { $0 + $1.cpu } / Double(windowStats.count)
            avgMem = windowStats.reduce(0.0) { $0 + $1.memory } / Double(windowStats.count)
            avgGpu = windowStats.reduce(0.0) { $0 + $1.gpu } / Double(windowStats.count)
        }

        return (avgCpu, avgMem, avgGpu, windowStats)
    }
}
