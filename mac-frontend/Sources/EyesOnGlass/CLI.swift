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
        let contents = (try? fm.contentsOfDirectory(atPath: baseDirectory)) ?? []
        // Dynamically find all video files for the full battery test
        let videoFiles = contents.filter { $0.hasSuffix(".mp4") || $0.hasSuffix(".ts") }.sorted()
        var resultsDict = [String: Any]()
        let executionTiers: [GemmaModelTier] = [.e4b]
        
        let offlineStreamController = await MainActor.run { 
            let ctrl = StreamController()
            ctrl.modelContext = container.mainContext
            return ctrl
        }
        
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let dateString = dateFormatter.string(from: Date())
        let outputFilename = isTestMode ? "test_analysis_results_\(dateString).json" : "analysis_results_\(dateString).json"
        let outputDirName = "analysis_results"
        
        for tier in executionTiers {
            fputs("\n==================================\n", stderr)
            fputs("RUNNING PIPELINE AGAINST TIER: \(tier.rawValue)\n", stderr)
            fputs("==================================\n", stderr)
            
            // Re-configure the NativeVLMClient instance for the current tier
            await NativeVLMClient.shared.prepareModel()
            fputs("VLM State after prepareModel: \(NativeVLMClient.shared.state)\n", stderr)
            
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
                let allLogs = (try? context.fetch(FetchDescriptor<VideoLog>())) ?? []
                allLogs.forEach { context.delete($0) }
                try? context.save()
                NativeVLMClient.shared.resetContext()
                
                // Invoke real UDP simulation framework bound to the VLM tier
                if !isTestMode {
                    await SimulatedLiveService.streamAndAnalyze(filename: filename, baseDirectory: baseDirectory, streamController: offlineStreamController)
                }                
                // Fetch logged results
                let fetchDescriptor = FetchDescriptor<VideoLog>()
                do {
                    let logs = try context.fetch(fetchDescriptor)
                    let detailsMap = logs.map { "\($0.issueType) [\($0.analysisEngine ?? "Unknown")]" }
                    var foundTypes = Array(Set(detailsMap)).sorted()
                    if isTestMode { foundTypes = ["mock_test_type"] }
                    
                    var videoResults = resultsDict[filename] as? [String: [String]] ?? [:]
                    videoResults[tier.rawValue] = foundTypes
                    resultsDict[filename] = videoResults
                    fflush(stdout)
                } catch {
                    print("    [Error] Failed to fetch logs: \(error)")
                    fflush(stdout)
                }
                
                // Export Results incrementally
                let jsonData = try JSONSerialization.data(withJSONObject: resultsDict, options: [.prettyPrinted])
                let outputDirURL = URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent(outputDirName)
                do {
                    try fm.createDirectory(at: outputDirURL, withIntermediateDirectories: true)
                    let jsonPath = outputDirURL.appendingPathComponent(outputFilename)
                    try jsonData.write(to: jsonPath)
                } catch {
                    fputs("    [Error] Failed to write analysis results to disk: \(error)\n", stderr)
                }
                
                // Cleanup staged file
                try? fm.removeItem(at: destURL)
            }
        }
        
        fputs("\nAnalysis completed successfully. Final output written to \(outputDirName)/\(outputFilename)\n", stderr)
        
        } catch {
            fputs("Framework error: \(error)\n", stderr)
        }
    }
}
