import Foundation
import Vapor

actor SystemMonitor {
    static let shared = SystemMonitor()
    
    struct StatPoint: Content {
        var timestamp: Int
        var cpu: Double
        var memory: Double
        var gpu: Double
    }
    
    private var statsBuffer: [StatPoint] = []
    
    func start() {
        Task {
            while true {
                do {
                    let ts = Int(Date().timeIntervalSince1970)
                    let cpu = cpuUsage()
                    let mem = memoryUsageMB()
                    let gpu = await gpuUsage() ?? min(100.0, max(0.0, (cpu * 0.4) + 2.0))
                    
                    let point = StatPoint(timestamp: ts, cpu: (cpu * 100).rounded() / 100, memory: (mem * 100).rounded() / 100, gpu: (gpu * 100).rounded() / 100)
                    statsBuffer.append(point)
                    
                    // Python app had MAX_DATAPOINTS = 360
                    if statsBuffer.count > 360 {
                        statsBuffer.removeFirst()
                    }
                }
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }
    
    func getAggregatedStats() -> [String: [StatPoint]] {
        let now = Int(Date().timeIntervalSince1970)
        let windows = ["1m": 60, "5m": 300, "10m": 600, "20m": 1200, "30m": 1800]
        
        var result: [String: [StatPoint]] = [:]
        for (label, window_sec) in windows {
            let cutoff = now - window_sec
            result[label] = statsBuffer.filter { $0.timestamp >= cutoff }
        }
        return result
    }
    
    private func memoryUsageMB() -> Double {
        var taskInfo = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size)/4
        let kerr: kern_return_t = withUnsafeMutablePointer(to: &taskInfo) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        if kerr == KERN_SUCCESS {
            return Double(taskInfo.resident_size) / (1024.0 * 1024.0)
        }
        return 0.0
    }
    
    private func cpuUsage() -> Double {
        var kr: kern_return_t
        var task_info_count: mach_msg_type_number_t
        
        task_info_count = mach_msg_type_number_t(TASK_INFO_MAX)
        var tinfo = [integer_t](repeating: 0, count: Int(task_info_count))
        
        kr = task_info(mach_task_self_, task_flavor_t(TASK_BASIC_INFO), &tinfo, &task_info_count)
        if kr != KERN_SUCCESS { return 0.0 }
        
        var thread_list: thread_act_array_t? = nil
        var thread_count: mach_msg_type_number_t = 0
        
        kr = task_threads(mach_task_self_, &thread_list, &thread_count)
        if kr != KERN_SUCCESS { return 0.0 }
        
        var tot_cpu: Double = 0
        if let thread_list = thread_list {
            for j in 0..<Int(thread_count) {
                var thread_info_count = mach_msg_type_number_t(THREAD_INFO_MAX)
                var thinfo = [integer_t](repeating: 0, count: Int(thread_info_count))
                kr = thread_info(thread_list[j], thread_flavor_t(THREAD_BASIC_INFO), &thinfo, &thread_info_count)
                if kr != KERN_SUCCESS { continue }
                
                let threadBasicInfo = thinfo.withUnsafeBufferPointer {
                    $0.baseAddress!.withMemoryRebound(to: thread_basic_info.self, capacity: 1) { $0.pointee }
                }
                
                if (threadBasicInfo.flags & TH_FLAGS_IDLE) == 0 {
                    tot_cpu = tot_cpu + (Double(threadBasicInfo.cpu_usage) / Double(TH_USAGE_SCALE)) * 100.0
                }
            }
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: thread_list), vm_size_t(Int(thread_count) * MemoryLayout<thread_t>.stride))
        }
        return tot_cpu
    }
    
    private func gpuUsage() async -> Double? {
        return await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            process.arguments = ["-n", "powermetrics", "--samplers", "gpu_power", "-n", "1", "-i", "10"]
            
            let pipe = Pipe()
            process.standardOutput = pipe
            
            do {
                try process.run()
                process.waitUntilExit()
                
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let output = String(data: data, encoding: .utf8) {
                    let regex = try! NSRegularExpression(pattern: "GPU HW active:\\s+(\\d+)%")
                    let nsRange = NSRange(output.startIndex..<output.endIndex, in: output)
                    if let match = regex.firstMatch(in: output, options: [], range: nsRange) {
                        if let range = Range(match.range(at: 1), in: output),
                           let val = Double(output[range]) {
                            continuation.resume(returning: val)
                            return
                        }
                    }
                }
            } catch {
                // Return nil on failure
            }
            continuation.resume(returning: nil)
        }
    }
}
