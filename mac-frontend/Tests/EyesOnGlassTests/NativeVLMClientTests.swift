import XCTest
@testable import EyesOnGlass

final class NativeVLMClientTests: XCTestCase {
    

    
    @MainActor
    func testPrepareModelFailsWithEmptyToken() async throws {
        let client = NativeVLMClient.shared
        
        // Reset state
        client.state = .notLoaded
        
        // Attempt to prepare without token
        await client.prepareModel(tier: .e4b, token: "")
        
        // Validate it throws the authentication error
        if case .error(let message) = client.state {
            XCTAssertTrue(message.contains("valid Hugging Face token is required"), "Should require a Hugging Face token.")
        } else {
            XCTFail("Expected an error regarding an empty token.")
        }
    }
    
    func testGemmaModelTierDisplayNames() {
        XCTAssertEqual(GemmaModelTier.e4b.displayName, "Gemma 4 E4B (Balanced)")
    }
    
    @MainActor
    func testAnalyzeFrameForIssuesReturnsEmptyWhenNotReady() async throws {
        let client = NativeVLMClient.shared
        client.state = .notLoaded
        
        let issues = await client.analyzeFrameForIssues(imagePath: "dummy_url.jpg", tier: .e4b)
        XCTAssertTrue(issues.isEmpty, "Should return empty dictionary when the model is not ready.")
    }
    
    // Feature Implementation Standard: Automated test for macroblocking explicit language validation
    func testMacroblockingPromptExplicitMandate() {
        let prompt = NativeVLMClient.macroblockingPrompt
        
        // Assert that the explicit taxonomy identifier is required
        XCTAssertTrue(prompt.contains("'macroblocking'"), "Prompt must explicitly mandate the taxonomy identifier 'macroblocking' as the valid JSON key to ensure accurate parsing.")
        
        // Assert json formatting restrictions are imposed on the MLX engine
        XCTAssertTrue(prompt.contains("valid JSON") && prompt.contains("'issues' mapping"), "Prompt must restrict output to valid JSON utilizing the 'issues' array map. Found: \(prompt)")
    }
    
    @MainActor
    func testNativeVLMClientKVInitialization() async throws {
        // Validates that the default selected tier strictly utilizes the e4b model
        // to maintain lower memory thresholds for the 350,000 token Pyramidal budget.
        let client = NativeVLMClient.shared
        XCTAssertEqual(client.selectedTier, .e4b, "Client should default to the highly compressed E4B tier to preserve memory for the 350,000 maxKVSize Pyramidal Token budget.")
    }
}

