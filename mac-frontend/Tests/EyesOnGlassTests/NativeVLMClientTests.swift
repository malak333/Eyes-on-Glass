import XCTest
@testable import EyesOnGlass

final class NativeVLMClientTests: XCTestCase {
    

    
    @MainActor
    func testPrepareModelFailsWithEmptyToken() async throws {
        let client = NativeVLMClient.shared
        
        // Reset state
        client.state = .notLoaded
        
        // Attempt to prepare (will fail if bundle is missing, but that confirms execution path)
        await client.prepareModel()
        
        // Validate state
        if case .error(let message) = client.state {
            XCTAssertTrue(message.contains("Model files not found") || message.contains("Insufficient Unified Memory"), "Should trigger a generic environment or bundle error.")
        } else {
            XCTFail("Expected an error regarding bundle/memory.")
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
        let prompt = NativeVLMClient.multimodalPrompt
        
        // Assert that the explicit taxonomy identifier is required
        XCTAssertTrue(prompt.contains("macroblocking"), "Prompt must explicitly mandate the taxonomy identifier 'macroblocking' as the valid JSON key to ensure accurate parsing.")
        
        // Assert json formatting restrictions are imposed on the MLX engine
        XCTAssertTrue(prompt.contains("valid JSON") && prompt.contains("schema:"), "Prompt must restrict output to valid JSON utilizing the schema. Found: \(prompt)")
    }
    
    // Feature Implementation Standard: Automated test for the zero-shot algorithmic gate
    func testStageAPromptAlgorithmicGate() {
        let prompt = NativeVLMClient.stageAPrompt
        
        // Assert that the explicit negative constraints are present
        XCTAssertTrue(prompt.contains("NOT macroblocking"), "Prompt must establish negative constraints for false-positives.")
        XCTAssertTrue(prompt.contains("sharp text overlay"), "Prompt must explicitly constrain text overlays.")
        XCTAssertTrue(prompt.contains("blurriness caused by natural high-speed motion"), "Prompt must explicitly constrain motion blur.")
        XCTAssertTrue(prompt.contains("compression ringing/noise"), "Prompt must explicitly constrain standard compression ringing/noise around graphics.")
        
        // Assert json formatting restrictions and MLX token limits are imposed
        XCTAssertTrue(prompt.contains("\"detected\": true/false"), "Prompt must explicitly define the expected detected boolean format.")
        XCTAssertTrue(prompt.contains("maximum 10-word summary"), "Prompt must explicitly constrain the description length to avoid hitting the 140 maxTokens limit during generation.")
    }
    
    @MainActor
    func testNativeVLMClientZeroShotInitialization() async throws {
        // Validates that the default selected tier strictly utilizes the e4b model
        // for stateless zero-shot inference.
        let client = NativeVLMClient.shared
        XCTAssertEqual(client.selectedTier, .e4b, "Client should default to the E4B tier for stateless zero-shot inference.")
    }
    
    // Feature Implementation Standard: Automated test for Audio Feature Response Parsing
    // Removed because the python audio daemon was pruned from the application.
    
    // Feature Implementation Standard: Automated test for logic additions ensuring isolation and strict typing
    func testAnomalySynonymNormalization() {
        let mappings: [(String, String)] = [
            ("slate", "slate"),
            ("Color Bars", "bars_and_tone"),
            ("frozen", "frozen_screen"),
            ("frozen screen", "frozen_screen"),
            ("distorted audio", "distorted_audio"),
            ("black screen", "black_screen"),
            ("static on video", "snowflakes"),
            ("snowflakes", "snowflakes"),
            ("audio drop out", "audio_drop_out"),
            ("lip sync issue", "lip_sync"),
            ("lip_sync", "lip_sync"),
            ("buzzing", "buzzing_audio"),
            ("no audio", "no_audio"),
            ("macroblocking", "macroblocking"),
            ("Top artifact", "top_artifact")
        ]
        
        for (input, expected) in mappings {
            let result = NativeVLMClient.normalizeAnomalyType(input)
            XCTAssertEqual(result, expected, "Failed properly normalizing '\(input)' to '\(expected)'. Found: '\(result)'.")
        }
    }
}

