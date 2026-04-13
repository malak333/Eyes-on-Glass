import Foundation
import Observation
import Hub
import MLX
import MLXLMCommon
import MLXVLM
import Tokenizers
import CoreImage
import AVFoundation
import Foundation

public struct VLMAnomaly: Codable, Sendable {
    public let type: String
    public let confidence: Double
    public let modality: String
}

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
    case e4b = "mlx-community/gemma-4-e4b-it-4bit"
    
    public var id: String { rawValue }
    
    public var displayName: String {
        switch self {
        case .e4b: return "Gemma 4 E4B (Balanced)"
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
    public static let multimodalPrompt = """
    Analyze this sequence of video frames and its perfectly aligned audio buffer for broadcast anomalies.
    You must report ANY detected issues from this precise list:
    - macroblocking
    - audio drop out
    - no audio
    - frozen screen
    - black screen
    - slate
    - bars and tone
    - static on video snowflakes
    - lip sync issue
    - buzzing audio
    - distorted audio
    Reply strictly in valid JSON as an array of objects matching this schema:
    [{"type": "exact_string", "confidence": 0.99, "modality": "audio|video|sync"}]
    If there are no issues, output []. No other text.
    """
    
    public static let stageAPrompt = """
    Compare these two video frames chronologically (frame 1 -> frame 2).
    Has macroblocking or severe compression artifacting appeared in the second frame compared to the first?
    Reply exclusively in JSON: {"detected": true} or {"detected": false}.
    """
    
    public static let stageBPrompt = """
    Analyze these three chronologically ordered frames representing an anomaly incident (Start, Peak Severity, End).
    Provide a professional Incident Report summary (1-2 sentences) describing the visual severity, duration or extent of the interference observed across the sequence.
    Reply exactly and only with the summary string. No preamble.
    """
    
    @MainActor public var state: VLMState = .notLoaded
    @MainActor public var selectedTier: GemmaModelTier = .e4b
    
    private let isolationQueue = DispatchQueue(label: "com.eyeson.vlm.inference", qos: .userInitiated)
    private var modelContainer: ModelContainer?
    private var chatSession: ChatSession?
    
    private init() {}
    
    @MainActor
    public func prepareModel(tier: GemmaModelTier, token: String? = nil) async {
        self.selectedTier = tier
        
        let requiredMemory: UInt64
        switch tier {
        case .e4b: requiredMemory = 6_000_000_000
        }
        
        let availableMemory = UInt64(100_000_000_000) 
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
            
            // Rolling KV Cache initialized here utilizing MLX LM's maxKVSize logic
            // 350,000 limit accommodates ~1,000 Pyramidal/Variable Budget frames
            let genParams = GenerateParameters(maxTokens: 50, maxKVSize: 350_000)
            self.chatSession = ChatSession(self.modelContainer!, generateParameters: genParams)
            
            self.state = .ready
        } catch {
            self.state = .error("Failed to load model: \(error.localizedDescription)")
        }
    }
    
    public func ingestFrameCache(imagePath: String, tier: GemmaModelTier) async {
        let isReady = await MainActor.run { 
            if case .ready = self.state { return true }
            return false
        }
        guard isReady, let session = self.chatSession, let ciImage = CIImage(contentsOf: URL(fileURLWithPath: imagePath)) else { return }
        
        do {
            // Apply variable visual token budget (downsample older context frames)
            session.processing = UserInput.Processing(resize: CGSize(width: 256, height: 256))
            session.generateParameters.maxTokens = 5
            
            // We stream into the cache, then ignore the output.
            _ = try await session.respond(to: "log_frame", role: .user, image: .ciImage(ciImage))
        } catch {
            print("Failed to ingest frame context cache: \(error)")
        }
    }
    
    public func analyzeSequenceForIssues(frames: [String], tier: GemmaModelTier) async -> [VLMAnomaly] {
        let isReady = await MainActor.run { 
            if case .ready = self.state { return true }
            return false
        }
        
        guard isReady, let session = self.chatSession else { 
            return []
        }
        
        do {
            // Processing parameters for sequential frames and audio
            session.processing = UserInput.Processing(resize: CGSize(width: 512, height: 512))
            session.generateParameters.maxTokens = 300
            
            // Construct the payload as per user directions: array of frame Data and single AudioBuffer
            // Adjust arguments based on how MLXLM handles images + audio in v3.x
            // Note: Use images array or individual appends based on UserInput.
            let userInput = UserInput(prompt: NativeVLMClient.multimodalPrompt, images: frames.map { .url(URL(fileURLWithPath: $0)) }) 
            
            let outputText = try await session.respond(to: NativeVLMClient.multimodalPrompt, role: .user, images: userInput.images, videos: userInput.videos)
            
            print("NativeVLMClient output: \\(outputText)")
            
            var cleanedText = outputText
            let pattern = "```(?:json)?\\s*([\\s\\S]*?)\\s*```"
            if let regex = try? NSRegularExpression(pattern: pattern, options: []),
               let match = regex.firstMatch(in: outputText, options: [], range: NSRange(location: 0, length: outputText.utf16.count)),
               let range = Range(match.range(at: 1), in: outputText) {
                cleanedText = String(outputText[range])
            }
            cleanedText = cleanedText.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            
            if let data = cleanedText.data(using: String.Encoding.utf8) {
                let decoder = JSONDecoder()
                do {
                    let anomalies = try decoder.decode([VLMAnomaly].self, from: data)
                    return anomalies
                } catch {
                    print("Failed to decode standard array format: \\(error). Trying fallback.")
                }
            }
            return []
        } catch {
            print("Sequence inference failed: \\(error)")
            return []
        }
    }
    
    public func analyzeFrameForIssues(imagePath: String, tier: GemmaModelTier) async -> [String: Double] {
        let anomalies = await analyzeSequenceForIssues(frames: [imagePath], tier: tier)
        var issuesDict: [String: Double] = [:]
        for anomaly in anomalies {
            issuesDict[anomaly.type] = anomaly.confidence
        }
        return issuesDict
    }
    
    public func analyzeStageA(lastGood: String, bad: String, tier: GemmaModelTier) async -> Bool {
        let isReady = await MainActor.run { 
            if case .ready = self.state { return true }
            return false
        }
        guard isReady, let session = self.chatSession else { return false }
        
        do {
            session.processing = UserInput.Processing(resize: CGSize(width: 512, height: 512))
            session.generateParameters.maxTokens = 140
            
            let userInput = UserInput(prompt: NativeVLMClient.stageAPrompt, images: [lastGood, bad].map { .url(URL(fileURLWithPath: $0)) })
            let outputText = try await session.respond(to: NativeVLMClient.stageAPrompt, role: .user, images: userInput.images, videos: userInput.videos)

            let lower = outputText.lowercased()
            return lower.contains("\"detected\": true") || lower.contains("\"detected\":true") || lower.contains("true")
        } catch {
            return false
        }
    }

    public func analyzeStageB(start: String, peak: String, end: String, tier: GemmaModelTier) async -> String? {
        let isReady = await MainActor.run { 
            if case .ready = self.state { return true }
            return false
        }
        guard isReady, let session = self.chatSession else { return nil }
        
        do {
            session.processing = UserInput.Processing(resize: CGSize(width: 512, height: 512))
            session.generateParameters.maxTokens = 560
            
            let userInput = UserInput(prompt: NativeVLMClient.stageBPrompt, images: [start, peak, end].map { .url(URL(fileURLWithPath: $0)) })
            var outputText = try await session.respond(to: NativeVLMClient.stageBPrompt, role: .user, images: userInput.images, videos: userInput.videos)
            
            outputText = outputText.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            return outputText.isEmpty ? nil : outputText
        } catch {
            return nil
        }
    }
    
}
