import XCTest
import SwiftData
@testable import EyesOnGlass

final class BatteryTestingCLITests: XCTestCase {
    
    @MainActor
    func testCLIExecutionInitialization() async throws {
        // Setup a mock directory with no files to quickly evaluate the CLI loop initialization
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("MockVideoAssets_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }
        
        let outputDirURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("analysis_results")
        if let contents = try? FileManager.default.contentsOfDirectory(atPath: outputDirURL.path) {
            for file in contents where file.hasPrefix("test_analysis_results_") {
                try? FileManager.default.removeItem(at: outputDirURL.appendingPathComponent(file))
            }
        }
        
        // Execute the CLI runner using the mock directory and in test mode to minimize execution overhead
        await BatteryTestingCLI.run(baseDirectory: tempDir.path, isTestMode: true)
        
        // If it returns successfully without crashing or hanging, execution loops are syntactically sound
        let newContents = try? FileManager.default.contentsOfDirectory(atPath: outputDirURL.path)
        let resultsFile = newContents?.first(where: { $0.hasPrefix("test_analysis_results_") })
        XCTAssertNotNil(resultsFile, "The CLI should generate a test_analysis_results JSON file even if empty.")
    }
    
    @MainActor
    func testCLIFiltersVideoExtensions() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("MockVideoAssets_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }
        
        let files = ["test.mp4", "test.ts", "test.mkv", "test.txt", ".hidden.mp4", "test.avi"]
        for file in files {
            let url = tempDir.appendingPathComponent(file)
            try "".data(using: .utf8)!.write(to: url)
        }
        
        let outputDirURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("analysis_results")
        if let contents = try? FileManager.default.contentsOfDirectory(atPath: outputDirURL.path) {
            for file in contents where file.hasPrefix("test_analysis_results_") {
                try? FileManager.default.removeItem(at: outputDirURL.appendingPathComponent(file))
            }
        }
        
        await BatteryTestingCLI.run(baseDirectory: tempDir.path, isTestMode: true)
        
        let newContents = try? FileManager.default.contentsOfDirectory(atPath: outputDirURL.path)
        guard let resultsFile = newContents?.first(where: { $0.hasPrefix("test_analysis_results_") }) else {
            XCTFail("Could not find test analysis_results file in directory")
            return
        }
        let resultsOutput = outputDirURL.appendingPathComponent(resultsFile)
        XCTAssertTrue(FileManager.default.fileExists(atPath: resultsOutput.path))
        
        if let data = try? Data(contentsOf: resultsOutput),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            XCTAssertTrue(json.keys.contains("test.mp4"), "Failed to identify .mp4 files")
            XCTAssertTrue(json.keys.contains("test.ts"), "Failed to identify .ts files")
            XCTAssertTrue(json.keys.contains("test.mkv"), "Failed to identify .mkv files")
            XCTAssertFalse(json.keys.contains("test.txt"), "Should ignore .txt")
            XCTAssertFalse(json.keys.contains("test.avi"), "Should ignore .avi")
        } else {
            XCTFail("Could not read analysis_results.json")
        }
    }
}
