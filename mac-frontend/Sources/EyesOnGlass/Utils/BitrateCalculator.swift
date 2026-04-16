import Foundation

struct BitrateState: Sendable {
    let bitrate: Double
    let isVBR: Bool
}

class BitrateCalculator: @unchecked Sendable {
    private var bitrateHistory: [Double] = []

    func update(delta: Int, elapsed: TimeInterval) -> BitrateState {
        let instBitrate = Double(delta) * 188.0 * 8.0 / elapsed / 1_000_000.0
        var isVBR = false

        if instBitrate > 0.1 {
            bitrateHistory.append(instBitrate)
            if bitrateHistory.count > 10 {
                bitrateHistory.removeFirst()
            }
            if bitrateHistory.count >= 5 {
                let maxB = bitrateHistory.max() ?? 0
                let minB = bitrateHistory.min() ?? 0
                if maxB > 0 && ((maxB - minB) / maxB > 0.10) {
                    isVBR = true
                }
            }
        }

        return BitrateState(bitrate: instBitrate, isVBR: isVBR)
    }

    func reset() {
        bitrateHistory.removeAll()
    }
}
