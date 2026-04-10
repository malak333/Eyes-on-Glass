import XCTest
@testable import EyesOnGlass

final class NativeVLMClientTests: XCTestCase {
    
    @MainActor
    func testPrepareModelSuccessfullyMocksDownload() async throws {
        let client = NativeVLMClient.shared
        
        // Reset state
        client.state = .notLoaded
        
        // Attempt to prepare a model (with a generic token, since we are mocking)
        await client.prepareModel(tier: .e2b, token: "dummy_token")
        
        // Validate that state advanced to ready instead of falling into an error state
        if case .ready = client.state {
            XCTAssertTrue(true, "Model prepared successfully.")
        } else if case .error(let message) = client.state {
            XCTFail("Expected .ready state, but got .error with message: \(message)")
        } else {
            XCTFail("Expected .ready state, but got another transient state.")
        }
    }
    
    @MainActor
    func testPrepareModelFailsWithEmptyToken() async throws {
        let client = NativeVLMClient.shared
        
        // Reset state
        client.state = .notLoaded
        
        // Attempt to prepare without token
        await client.prepareModel(tier: .e2b, token: "")
        
        // Validate it throws the authentication error
        if case .error(let message) = client.state {
            XCTAssertTrue(message.contains("valid Hugging Face token is required"), "Should require a Hugging Face token.")
        } else {
            XCTFail("Expected an error regarding an empty token.")
        }
    }
    
    func testGemmaModelTierDisplayNames() {
        XCTAssertEqual(GemmaModelTier.e2b.displayName, "Gemma 4 E2B (Fastest)")
        XCTAssertEqual(GemmaModelTier.e4b.displayName, "Gemma 4 E4B (Balanced)")
        XCTAssertEqual(GemmaModelTier.b26.displayName, "Gemma 4 26B-A4B (MoE, Heavy)")
        XCTAssertEqual(GemmaModelTier.b31.displayName, "Gemma 4 31B (Dense, Ultra)")
    }
}
