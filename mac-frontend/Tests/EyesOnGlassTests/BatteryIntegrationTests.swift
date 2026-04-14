import XCTest
import SwiftData
@testable import EyesOnGlass

final class BatteryIntegrationTests: XCTestCase {
    
    // Configured based on user request mapping
    let expectedAnomalies: [String: [String]] = [
        "ABCNHOU_KTRK_AUDIO_DROP_0427PMET.ts": ["no_audio"],
        "bad-sdi.ts": ["no_audio", "clicking_audio"],
        "CC4Sencore.ts": ["no_audio", "black_screen", "top_artifact"],
        "CIRCLE TS_2020_05_03_15_29_00_078.mp4": ["macroblocking"],
        "KGO-VOD-Encoder.ts": ["black_screen", "static_audio"],
        "kgot-sfo-disney-e2-cap2.ts": ["clicking_audio"],
        "KTXL ATSC 3 Sync issue pre-reset.ts": ["lip_sync"],
        "missing packets digitenne 482000 06-30 19-43-54.ts": ["macroblocking", "no_audio"],
        "nic_monitor-lo-127.0.0.1.4999-20220117-221148.ts": [],
        "nic_monitor-net0-227.1.1.4.4004-20220117-221435.ts": ["no_audio", "macroblocking", "top_artifact", "lip_sync"],
        "nic_monitor-net0-227.1.1.13.4013-20241217-123649.ts": ["no_audio"],
        "nic_monitor-net0-227.1.1.17.4017-20230303-181538.ts": ["buzzing_audio"],
        "nic_monitor-net0-227.1.1.17.4017-20230303-182411.ts": ["buzzing_audio"],
        "out-2022.03.02.02.11.50-230.0.187.21.ts": [],
        "nic_monitor-net0-227.1.1.17.4017-20230316-124211.ts": ["buzzing_audio"],
        "out-2022.03.02.02.46.52-230.0.187.23.ts": ["macroblocking", "no_audio", "lip_sync"],
        "out-2022.05.14.12.07.19-230.0.33.24.ts": ["no_audio", "top_artifact"],
        "out-2022.10.27.02.24.53-232.0.168.4.ts": [],
        "out-2022.10.28.12.40.00-232.0.168.4.ts": [],
        "out-2023.02.03.10.53.48-233.0.140.19.ts": ["no_audio"],
        "out-2023.03.16.01.28.58-233.99.164.38.ts": ["buzzing_audio"],
        "out-2023.06.22.11.37.06-230.0.201.41.ts": ["lip_sync"],
        "out-2024.02.11.06.54.11-233.0.18.19.ts": ["lip_sync", "macroblocking"],
        "out-2025.04.14.12.26.04-234.0.100.91.ts": [],
        "stlu-chaifetz-audio2.ts": [],
        "wpvi-capture.ts": ["no_audio"],
        "yale-test1.ts": ["no_audio"],
        "mhz-wv-hd2.ts": ["top_artifact", "clicking_audio"],
        "orioles-10MB.ts": ["snowflakes", "no_audio", "lip_sync", "macroblocking", "clicking_audio"],
        "kabc-20MB.ts": ["black_screen"]
    ]
    
    let baseDirectory = "/Users/michaelnobile/Video Assets"
    
    @MainActor
    func testBatteryAssets() async throws {
        self.continueAfterFailure = true // Continue processing all files even if one fails
        
        let startTestTime = CFAbsoluteTimeGetCurrent()
        for (filename, expected) in expectedAnomalies where filename == "kabc-20MB.ts" {
            print("\n=== Testing \(filename) ===")
            let fileURL = URL(fileURLWithPath: "\(baseDirectory)/\(filename)")
            
            // 1. Verify Asset Exists
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                XCTFail("Asset missing: \(filename)")
                continue
            }
            
            // 2. Initialize localized isolated SwiftData context
            let config = ModelConfiguration(isStoredInMemoryOnly: true)
            let container = try ModelContainer(for: VideoLog.self, configurations: config)
            let context = container.mainContext
            // 4. Setup StreamController state
            StreamController.shared.modelContext = context
            StreamController.shared.currentSessionIdentifier = filename
            StreamController.shared.currentSessionStartTime = Date()
            
            // 5. Stage file for ExtractionService
            let fileManager = FileManager.default
            let uploadsDir = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!.appendingPathComponent("EyesOnGlass/Uploads/")
            try? fileManager.createDirectory(at: uploadsDir, withIntermediateDirectories: true)
            let destURL = uploadsDir.appendingPathComponent(filename)
            
            if fileManager.fileExists(atPath: destURL.path) {
                try? fileManager.removeItem(at: destURL)
            }
            try fileManager.copyItem(at: fileURL, to: destURL)
            
            // 6. Execute offline extraction synchronously
            await ExtractionService.extractAndAnalyze(filename: filename)
            
            // 7. Database Interrogation
            let fetchDescriptor = FetchDescriptor<VideoLog>()
            let logs = try context.fetch(fetchDescriptor)
            
            // Filter out system connectivity/state events
            let ignorableEvents: Set<String> = ["ok", "video_restored", "audio_restored", "video_lost", "stream_lost", "audio_lost"]
            let allIssues = logs.map { $0.issueType }
            let detectedIssues = Set(allIssues.filter { !ignorableEvents.contains($0) })
            
            let expectedSet = Set(expected)
            let isSuperset = detectedIssues.isSuperset(of: expectedSet)
            
            if !isSuperset {
                let missing = expectedSet.subtracting(detectedIssues)
                XCTFail("Failed \(filename). M:\(missing) | D:\(detectedIssues) | TotalLogs: \(logs.count)")
            } else {
                print("PASS: \(filename) (Found expected issues within \(detectedIssues))")
            }
        }
        
        let endTestTime = CFAbsoluteTimeGetCurrent()
        let elapsed = endTestTime - startTestTime
        let mbProcessed = Double(759_955_456) / 1_000_000.0 // True file size of kabc-20MB.ts in MB
        let mbPerSecond = mbProcessed / elapsed
        let streams20Mbps = mbPerSecond / 2.5
        
        print("\n\n====== FULL PIPELINE BENCHMARK (kabc-20MB.ts) ======")
        print("Total elapsed time: \(String(format: "%.3f", elapsed)) s for \(mbProcessed) MB")
        print("Pipeline Throughput: \(String(format: "%.2f", mbPerSecond)) MB/sec")
        print("Maximum 20Mbps Streams (per isolated process): \(String(format: "%.2f", streams20Mbps))")
        print("=======================================================\n")
    }
}
