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
        
        // Execute the CLI runner using the mock directory and in test mode to minimize execution overhead
        await BatteryTestingCLI.run(baseDirectory: tempDir.path, isTestMode: true)
        
        // If it returns successfully without crashing or hanging, execution loops are syntactically sound
        let resultsOutput = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("analysis_results.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: resultsOutput.path), "The CLI should generate an analysis_results.json even if empty.")
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
        
        await BatteryTestingCLI.run(baseDirectory: tempDir.path, isTestMode: true)
        
        let resultsOutput = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("analysis_results.json")
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
