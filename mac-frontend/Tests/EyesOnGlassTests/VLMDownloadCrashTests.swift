import XCTest
@testable import EyesOnGlass
import Hub
import MLXVLM

final class VLMDownloadCrashTests: XCTestCase {
    func testGemma4LoadContainer() async throws {
        let repo = Hub.Repo(id: "mlx-community/gemma-4-e2b-it-4bit")
        let hub = HubApi()
        
        print("Downloading all model files for snapshot...")
        let dir = try await hub.snapshot(from: repo, matching: ["*.json", "*.safetensors", "*.model"])
        print("Snapshot downloaded to: \\(dir)")
        
        do {
            print("Trying to load container...")
            // Use the same method NativeVLMClient uses!
            let container = try await VLMModelFactory.shared.loadContainer(
                from: dir,
                using: EyesOnGlassTokenizerLoader()
            )
            print("Container loaded! \\(container)")
        } catch {
            print("CAUGHT ERROR: \\(error)")
            XCTFail("Caught error: \\(error)")
        }
    }
}
