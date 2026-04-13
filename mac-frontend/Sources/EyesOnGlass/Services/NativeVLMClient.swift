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
    public static let macroblockingPrompt = "Analyze this video frame for broadcast anomalies. If you see any noticeable pixelation, blockiness, or compression artifacts, you must identify it precisely as 'macroblocking'. Be highly sensitive to these artifacts. Reply exclusively in valid JSON with a single key 'issues' mapping to an array of objects. Example: {\"issues\": [{\"type\": \"macroblocking\", \"confidence\": 0.9}]}. No other text."
    
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
    
    public func analyzeFrameForIssues(imagePath: String, tier: GemmaModelTier) async -> [String: Double] {
        // Ensure state is checked safely via MainActor
        let isReady = await MainActor.run { 
            if case .ready = self.state { return true }
            return false
        }
        
        guard isReady else { 
            return [:]
        }
        
        
        guard let ciImage = CIImage(contentsOf: URL(fileURLWithPath: imagePath)), let session = self.chatSession else {
            return [:]
        }
        
        let prompt = NativeVLMClient.macroblockingPrompt
        
        do {
            // High token budget relative to context frames for exact precision checks
            session.processing = UserInput.Processing(resize: CGSize(width: 1024, height: 1024))
            session.generateParameters.maxTokens = 100
            
            let outputText = try await session.respond(to: prompt, role: .user, image: .ciImage(ciImage))
            
            print("NativeVLMClient output: \(outputText)")
            
            var cleanedText = outputText
            let pattern = "```(?:json)?\\s*([\\s\\S]*?)\\s*```"
            if let regex = try? NSRegularExpression(pattern: pattern, options: []),
               let match = regex.firstMatch(in: outputText, options: [], range: NSRange(location: 0, length: outputText.utf16.count)),
               let range = Range(match.range(at: 1), in: outputText) {
                cleanedText = String(outputText[range])
            } else {
                let bracePattern = "\\{[\\s\\S]*\\}"
                if let braceRegex = try? NSRegularExpression(pattern: bracePattern, options: []),
                   let match = braceRegex.firstMatch(in: outputText, options: [], range: NSRange(location: 0, length: outputText.utf16.count)),
                   let range = Range(match.range, in: outputText) {
                    cleanedText = String(outputText[range])
                }
            }
            cleanedText = cleanedText.trimmingCharacters(in: .whitespacesAndNewlines)
            
            var issuesDict: [String: Double] = [:]
            
            if let data = cleanedText.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                
                var itemsToProcess: [[String: Any]] = []
                if let issuesArray = json["issues"] as? [[String: Any]] {
                    itemsToProcess = issuesArray
                } else if let issueObj = json["issues"] as? [String: Any] {
                    itemsToProcess.append(issueObj)
                } else if json["type"] is String {
                    itemsToProcess.append(json)
                }
                
                for issueObj in itemsToProcess {
                    if var type = issueObj["type"] as? String {
                        let typeLower = type.lowercased()
                        if typeLower.contains("macroblocking") || typeLower.contains("compression") || typeLower.contains("pixelation") || typeLower.contains("blockiness") || typeLower.contains("artifact") {
                            type = "macroblocking"
                        }
                        
                        if let confidence = issueObj["confidence"] as? Double {
                            issuesDict[type] = confidence
                        } else if let confidenceNum = issueObj["confidence"] as? NSNumber {
                            issuesDict[type] = confidenceNum.doubleValue
                        } else if let confString = issueObj["confidence"] as? String, let confDbl = Double(confString) {
                            issuesDict[type] = confDbl
                        } else {
                            issuesDict[type] = 0.8
                        }
                    }
                }
                
                if itemsToProcess.isEmpty, let stringArray = json["issues"] as? [String] {
                    for typeString in stringArray {
                        let typeLower = typeString.lowercased()
                        var type = typeString
                        if typeLower.contains("macroblocking") || typeLower.contains("compression") || typeLower.contains("pixelation") || typeLower.contains("blockiness") || typeLower.contains("artifact") {
                            type = "macroblocking"
                        }
                        issuesDict[type] = 0.8
                    }
                }
            } else {
                print("NativeVLMClient parsing failed or not valid JSON. Cleaned text: \(cleanedText)")
            }
            
            // Resilient fallback for models that output non-standard formats containing macroblocking signals
            if issuesDict.isEmpty {
                let lowerText = cleanedText.lowercased()
                let emptyArrayPattern = "\"issues\"\\s*:\\s*\\[\\s*\\]"
                let hasEmptyArray = lowerText.range(of: emptyArrayPattern, options: .regularExpression) != nil
                
                if !hasEmptyArray {
                    if lowerText.contains("macroblocking") || lowerText.contains("compression") || 
                       lowerText.contains("pixelation") || lowerText.contains("blockiness") || 
                       lowerText.contains("artifact") {
                        issuesDict["macroblocking"] = 0.8
                    }
                }
            }
            
            return issuesDict
        } catch {
            print("Frame inference failed: \(error)")
            return [:]
        }
    }
}
