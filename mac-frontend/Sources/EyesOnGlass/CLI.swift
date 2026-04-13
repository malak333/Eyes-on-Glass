import Foundation
import SwiftData

let baseDirectory = "/Users/michaelnobile/Video Assets"
    let tiersToRun: [GemmaModelTier] = [.e4b]
    
    @MainActor
    public struct BatteryTestingCLI {
        static func run(baseDirectory: String = "/Users/michaelnobile/Video Assets", isTestMode: Bool = false) async {
            fputs("Starting Multi-Model Analysis Framework...\n", stderr)
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container: ModelContainer
    do {
        container = try ModelContainer(for: VideoLog.self, configurations: config)
    } catch {
        print("Failed to initialize SwiftData: \(error)")
        return
    }
    
    // Inject the isolated context into the StreamController so offline background extractions are preserved
    await MainActor.run {
        StreamController.shared.modelContext = container.mainContext
    }
    
    let fm = FileManager.default
    guard fm.fileExists(atPath: baseDirectory) else {
        print("Video directory missing: \(baseDirectory)")
        return
    }
    
    // Create Uploads directory
    let documentsURL = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
    let eogURL = documentsURL.appendingPathComponent("EyesOnGlass")
    let uploadsDir = eogURL.appendingPathComponent("Uploads")
    try? fm.createDirectory(at: uploadsDir, withIntermediateDirectories: true)
    
    do {
        let files = try fm.contentsOfDirectory(atPath: baseDirectory)
        var videoFiles = files.filter { $0.hasSuffix(".ts") || $0.hasSuffix(".mp4") }.sorted()
        videoFiles = videoFiles.filter { $0 == "kabc-20MB.ts" || $0 == "CIRCLE TS_2020_05_03_15_29_00_078.mp4" }
        
        var resultsDict = [String: Any]()
        let executionTiers: [GemmaModelTier] = [.e4b]
        
        for tier in executionTiers {
            fputs("\n==================================\n", stderr)
            fputs("RUNNING PIPELINE AGAINST TIER: \(tier.rawValue)\n", stderr)
            fputs("==================================\n", stderr)
            
            // Re-configure the NativeVLMClient instance for the current tier
            // We use a simulated token since it's a simulated MLX framework for now.
            let hfToken = ProcessInfo.processInfo.environment["HF_TOKEN"] ?? "mock_token"
            await NativeVLMClient.shared.prepareModel(tier: tier, token: hfToken)
            
            for filename in videoFiles {
                fputs(" -> Processing \(filename) [\(tier.displayName)]...\n", stderr)
                let sourceURL = URL(fileURLWithPath: "\(baseDirectory)/\(filename)")
                let destURL = uploadsDir.appendingPathComponent(filename)
                
                if fm.fileExists(atPath: destURL.path) {
                    try? fm.removeItem(at: destURL)
                }
                
                do {
                    try fm.copyItem(at: sourceURL, to: destURL)
                } catch {
                    print("    [Error] Failed to copy \(filename): \(error)")
                    continue
                }
                
                // Clear state for isolated tests
                let context = container.mainContext
                try? context.delete(model: VideoLog.self)
                
                // Invoke real offline extraction framework bound to the VLM tier
                await ExtractionService.extractAndAnalyze(filename: filename)
                
                // Fetch logged results
                let fetchDescriptor = FetchDescriptor<VideoLog>()
                do {
                    let logs = try context.fetch(fetchDescriptor)
                    let foundTypes = Array(Set(logs.map { $0.issueType })).sorted()
                    
                    var videoResults = resultsDict[filename] as? [String: [String]] ?? [:]
                    videoResults[tier.rawValue] = foundTypes
                    resultsDict[filename] = videoResults
                    
                    print("    [Result] Found \(logs.count) logs | Unique Anomalies: \(foundTypes)")
                    fflush(stdout)
                } catch {
                    print("    [Error] Failed to fetch logs: \(error)")
                    fflush(stdout)
                }
                
                // Cleanup staged file
                try? fm.removeItem(at: destURL)
            }
        }
        
        // Export Results to JSON
        fputs("\nExporting aggregated analysis results...\n", stderr)
        let jsonData = try JSONSerialization.data(withJSONObject: resultsDict, options: [.prettyPrinted])
        let jsonPath = URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("analysis_results.json")
        try jsonData.write(to: jsonPath)
        fputs("Analysis completed successfully. Output written to: \(jsonPath.path)\n", stderr)
        
        } catch {
            fputs("Framework error: \(error)\n", stderr)
        }
    }
}
