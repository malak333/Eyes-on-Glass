import XCTest
@testable import EyesOnGlass

final class NativeVLMClientTests: XCTestCase {
    
    @MainActor
    func testPrepareModelChecksInsufficientMemoryOrFailsGracefully() async throws {
        let client = NativeVLMClient.shared
        
        // Reset state
        client.state = .notLoaded
        
        // Attempt to prepare a high-tier model which should dynamically trigger an error
        // or attempt downloading if token is provided. Since we don't want to download 30GB,
        // we'll pass an impossible token format, ensuring the client properly validates.
        await client.prepareModel(tier: .b31, token: "invalid_format_token")
        
        // Validate that state correctly moved to an error indicating authentication or memory limits,
        // proving the mock was removed and true validation sits in the pipeline.
        if case .error(let message) = client.state {
            XCTAssertTrue(message.contains("Memory") || message.contains("Token") || message.contains("401"), "Properly caught environmental boundaries natively: \(message)")
        } else {
            XCTFail("Expected .error state due to memory limits or token validity on .b31, but got \(client.state).")
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
