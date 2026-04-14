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
    Look at the images provided. Focus on the final image. Describe what you see in 1 sentence, specifically whether it exhibits severe macroblocking (large colored visual artifacts, heavy blocky pixelation).
    Reply exclusively in valid JSON format: {"description": "...", "detected": true/false}.
    """
    
    public static let stageBPrompt = """
    You are an expert video broadcast analyst. Three chronologically ordered images are provided with this prompt representing a macroblocking video anomaly incident (Start, Peak Severity, and End).
    Analyze the provided images and write a concise, professional Incident Report summary (1-2 sentences) describing the visual severity, duration, and progression of the interference across the sequence.
    Do not output templates, examples, or questions. Reply exactly and only with the final summary string.
    """
    
    @MainActor public var state: VLMState = .notLoaded
    @MainActor public var selectedTier: GemmaModelTier = .e4b
    
    private let isolationQueue = DispatchQueue(label: "com.eyeson.vlm.inference", qos: .userInitiated)
    private var modelContainer: ModelContainer?
    private var chatSession: ChatSession?
    
    private init() {}
    
    @MainActor
    public func prepareModel() async {
        let requiredMemory: UInt64 = 6_000_000_000
        let availableMemory = ProcessInfo.processInfo.physicalMemory
        if availableMemory < requiredMemory {
            self.state = .error("Insufficient Unified Memory for Gemma 4 E4B")
            return
        }
        
        self.state = .loadingToMemory
        
        do {
            guard let modelDir = Bundle.module.url(forResource: "GemmaModel", withExtension: nil) else {
                self.state = .error("Model files not found in app bundle. Was the build script run?")
                return
            }
            
            self.modelContainer = try await VLMModelFactory.shared.loadContainer(
                from: modelDir,
                using: EyesOnGlassTokenizerLoader()
            )
            
            // Initialize ChatSession with a lowered KV limit strictly for localized zero-shot context
            let genParams = GenerateParameters(maxTokens: 50, maxKVSize: 10_000)
            self.chatSession = ChatSession(self.modelContainer!, generateParameters: genParams)
            
            self.state = .ready
        } catch {
            let errorMsg = "Failed to load model: \(error.localizedDescription)"
            print(errorMsg)
            fflush(stdout)
            self.state = .error(errorMsg)
        }
    }
    
    @MainActor
    public func resetContext() {
        if let container = self.modelContainer {
            let genParams = GenerateParameters(maxTokens: 50, maxKVSize: 10_000)
            self.chatSession = ChatSession(container, generateParameters: genParams)
        }
    }
    

    
    public func analyzeSequenceForIssues(frames: [String], tier: GemmaModelTier) async -> [VLMAnomaly] {
        let isReady = await MainActor.run { 
            if case .ready = self.state { return true }
            return false
        }
        
        await MainActor.run { self.resetContext() }
        
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
            
            print("NativeVLMClient output: \(outputText)")
            fflush(stdout)
            
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
                    return anomalies.map { anomaly in
                        return VLMAnomaly(type: NativeVLMClient.normalizeAnomalyType(anomaly.type), confidence: anomaly.confidence, modality: anomaly.modality)
                    }
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
        
        await MainActor.run { self.resetContext() }
        
        guard isReady, let session = self.chatSession else { return false }
        
        do {
            session.processing = UserInput.Processing(resize: CGSize(width: 512, height: 512))
            session.generateParameters.maxTokens = 140
            
            let userInput = UserInput(prompt: NativeVLMClient.stageAPrompt, images: [lastGood, bad].map { .url(URL(fileURLWithPath: $0)) })
            let outputText = try await session.respond(to: NativeVLMClient.stageAPrompt, role: .user, images: userInput.images, videos: userInput.videos)

            let lower = outputText.lowercased()
            fputs("Stage A output: \(outputText)\n", stderr)
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
        
        await MainActor.run { self.resetContext() }
        
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
    
    public static func normalizeAnomalyType(_ type: String) -> String {
        let newType = type.lowercased().replacingOccurrences(of: " ", with: "_")
        if newType.contains("slate") { return "slate" }
        if newType.contains("bars") { return "bars_and_tone" }
        if newType.contains("frozen") { return "frozen_screen" }
        if newType.contains("distort") { return "distorted_audio" }
        if newType.contains("black") { return "black_screen" }
        if newType.contains("snow") || newType.contains("static") { return "snowflakes" }
        if newType.contains("audio_drop") || newType.contains("drop_out") { return "audio_drop_out" }
        if newType.contains("lip_sync") { return "lip_sync" }
        if newType.contains("buzz") { return "buzzing_audio" }
        if newType.contains("no_audio") { return "no_audio" }
        if newType.contains("macroblock") { return "macroblocking" }
        if newType.contains("click") { return "clicking_audio" }
        if newType.contains("top_artifact") { return "top_artifact" }
        return newType
    }
}
