import Foundation

actor ExtractionProgress {
    static let shared = ExtractionProgress()
    
    struct ProgressData: Codable {
        var status: String
        var current: Int
        var total: Int
        var start_time: Double
        var packets: Int?
    }
    
    private var storage: [String: ProgressData] = [:]
    
    func set(status: String, current: Int, total: Int, for filename: String) {
        if let existing = storage[filename] {
            storage[filename] = ProgressData(status: status, current: current, total: total, start_time: existing.start_time, packets: existing.packets)
        } else {
            storage[filename] = ProgressData(status: status, current: current, total: total, start_time: Date().timeIntervalSince1970, packets: 0)
        }
    }
    
    func setPackets(_ packets: Int, for filename: String) {
        if let existing = storage[filename] {
            storage[filename] = ProgressData(status: existing.status, current: existing.current, total: existing.total, start_time: existing.start_time, packets: packets)
        }
    }
    
    func all() -> [String: ProgressData] {
        return storage
    }
}
