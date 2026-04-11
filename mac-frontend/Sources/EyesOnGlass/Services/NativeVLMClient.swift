import Foundation
import Observation
import Hub
import MLX
import MLXLMCommon
import MLXVLM
import Tokenizers
import CoreImage

public struct EyesOnGlassTokenizerLoader: MLXLMCommon.TokenizerLoader {
    public init() {}
    public func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        let upstream = try await AutoTokenizer.from(modelFolder: directory)
        return TokenizerBridge(upstream)
    }
}

struct TokenizerBridge: MLXLMCommon.Tokenizer {
    private let upstream: any Tokenizers.Tokenizer

    init(_ upstream: any Tokenizers.Tokenizer) {
        self.upstream = upstream
    }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? {
        upstream.convertTokenToId(token)
    }

    func convertIdToToken(_ id: Int) -> String? {
        upstream.convertIdToToken(id)
    }

    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        do {
            return try upstream.applyChatTemplate(
                messages: messages, tools: tools, additionalContext: additionalContext)
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}

public enum GemmaModelTier: String, CaseIterable, Identifiable {
    case e2b = "Google/gemma-4-e2b-mlx-4bit"
    case e4b = "Google/gemma-4-e4b-mlx-4bit"
    case b26 = "Google/gemma-4-26b-a4b-mlx-4bit"
    case b31 = "Google/gemma-4-31b-mlx-4bit"
    
    public var id: String { rawValue }
    
    public var displayName: String {
        switch self {
        case .e2b: return "Gemma 4 E2B (Fastest)"
        case .e4b: return "Gemma 4 E4B (Balanced)"
        case .b26: return "Gemma 4 26B-A4B (MoE, Heavy)"
        case .b31: return "Gemma 4 31B (Dense, Ultra)"
        }
    }
}

public enum VLMState {
    case notLoaded
    case downloading(progress: Double)
    case loadingToMemory
    case ready
    case error(String)
}

@Observable
public final class NativeVLMClient {
    public static let shared = NativeVLMClient()
    
    @MainActor public var state: VLMState = .notLoaded
    @MainActor public var selectedTier: GemmaModelTier = .e2b
    
    private let isolationQueue = DispatchQueue(label: "com.eyeson.vlm.inference", qos: .userInitiated)
    private var modelContainer: ModelContainer?
    
    private init() {}
    
    @MainActor
    public func prepareModel(tier: GemmaModelTier, token: String? = nil) async {
        self.selectedTier = tier
        
        let requiredMemory: UInt64
        switch tier {
        case .e2b: requiredMemory = 4_000_000_000
        case .e4b: requiredMemory = 6_000_000_000
        case .b26: requiredMemory = 16_000_000_000
        case .b31: requiredMemory = 22_000_000_000
        }
        
        let availableMemory = ProcessInfo.processInfo.physicalMemory / 2 
        if availableMemory < requiredMemory {
            self.state = .error("Insufficient Unified Memory for \(tier.displayName)")
            return
        }
        
        if token?.isEmpty ?? true {
            self.state = .error("A valid Hugging Face token is required to download Gemma models.")
            return
        }
        
        self.state = .downloading(progress: 0.0)
        
        do {
            let hub = HubApi(hfToken: token?.isEmpty == false ? token : nil)
            let repo = Hub.Repo(id: tier.rawValue)
            
            // In reality, we'd use the snapshot endpoint
            let modelDir = try await hub.snapshot(from: repo) { progress in
                Task { @MainActor in
                    self.state = .downloading(progress: progress.fractionCompleted)
                }
            }
            
            self.state = .loadingToMemory
            
            self.modelContainer = try await VLMModelFactory.shared.loadContainer(
                from: modelDir,
                using: EyesOnGlassTokenizerLoader()
            )
            
            self.state = .ready
        } catch {
            self.state = .error("Failed to load model: \(error.localizedDescription)")
        }
    }
    
    public func analyzeFrame(imagePath: String, tier: GemmaModelTier) async -> (isSlate: Bool, confidence: Double) {
        // Ensure state is checked safely via MainActor
        let isReady = await MainActor.run { 
            if case .ready = self.state { return true }
            return false
        }
        
        guard isReady else { 
            return (false, 0.0) 
        }
        
        
        guard let url = URL(string: imagePath), let ciImage = CIImage(contentsOf: url), let container = self.modelContainer else {
            return (false, 0.0)
        }
        
        let prompt = "Does this frame appear to be a static slate or holding screen? Reply exclusively in valid JSON with keys 'is_slate' (boolean) and 'confidence' (float between 0.0 and 1.0). No other text."
        
        do {
            let userInput = UserInput(prompt: prompt, images: [.ciImage(ciImage)])
            let input = try await container.prepare(input: userInput)
            let stream = try await container.generate(
                input: input,
                parameters: GenerateParameters(temperature: 0.0)
            )
            
            var outputText = ""
            for try await event in stream {
                if case .chunk(let text) = event {
                    outputText += text
                }
            }
            
            guard let data = outputText.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return (false, 0.0)
            }
            
            let isSlate = json["is_slate"] as? Bool ?? false
            let confidence = json["confidence"] as? Double ?? 0.0
            return (isSlate, confidence)
        } catch {
            print("Frame inference failed: \(error)")
            return (false, 0.0)
        }
    }
}
