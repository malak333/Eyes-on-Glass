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
    - macroblocking (Severe compression artifacts, blocky digital pixel starvation, or structural tearing. NOTE: do NOT flag clean static broadcast graphics, logos, slates, or fast commercial screen wipes/crossfades as macroblocking, even if they exhibit brief artifacting during the transition.)
    - audio drop out
    - no audio
    - frozen screen
    - black screen
    - slate (Use this for clean, flat-color broadcast graphics, logos, or station IDs)
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
    You are an expert video quality auditor. Compare the provided chronologically ordered images (Frame A: Previous, Frame B: Suspected Issue).
    Your task is to determine if Frame B exhibits severe macroblocking (digital pixel starvation) compared to Frame A.

    Evaluation Gate:
    1. Is the image a deliberate broadcast graphic, commercial slate, or transition wipe (e.g., flat background, prominent logos, station IDs, text, fading commercial)? If yes, it is NOT macroblocking.
    2. Does the image display severe, destructive blocky square artifacts that tear apart the underlying video picture? If yes, this IS macroblocking.
    3. Do NOT reject an image just because the background looks like a flat gradient or texture. 
    4. Focus heavily on structural tearing and blocky pixel starvation.

    Reply exclusively in valid JSON format. Mentally evaluate the gate, but provide ONLY a concise, maximum 10-word summary of your reasoning in the description.
    {"description": "...", "detected": true/false}
    """
    
    public static let stageBPrompt = """
    You are an expert video broadcast analyst. Three chronologically ordered images are provided with this prompt representing a macroblocking video anomaly incident (Start, Peak Severity, and End).
    Analyze the provided images and write a concise, professional Incident Report summary (1-2 sentences) describing the visual severity, duration, and progression of the interference across the sequence.
    Do not output templates, examples, or questions. Reply exactly and only with the final summary string.
    """
    
    public static let blackScreenPrompt = """
    You are an expert broadcast video technical analyst. Analyze these three chronologically ordered images (Frame A: Pre-black, Frame B: Black period, Frame C: Post-black restored).
    Determine if the black screen is a deliberate "creative transition" (e.g. fading to commercial, ending credits, dramatic pause, logo wipe) or a "technical failure" (unintended loss of video signal).
    
    Evaluation Gate:
    1. If Frame C resumes the same content, or cuts cleanly to a commercial, or shows credits fading in/out, it is a creative transition.
    2. If the black screen appears completely broken or jarring and does not look like a broadcast element, it is a technical failure.
    
    Reply exclusively in valid JSON format:
    {"is_technical_failure": true/false, "reasoning": "brief 1-sentence explanation"}
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
            let blockPattern = "```(?:json)?\\s*([\\s\\S]*?)\\s*```"
            let arrayPattern = "(\\[\\s*\\{[\\s\\S]*\\}\\s*\\])"
            
            if let regex = try? NSRegularExpression(pattern: blockPattern, options: []),
               let match = regex.firstMatch(in: outputText, options: [], range: NSRange(location: 0, length: outputText.utf16.count)),
               let range = Range(match.range(at: 1), in: outputText) {
                cleanedText = String(outputText[range])
            } else if let arrayRegex = try? NSRegularExpression(pattern: arrayPattern, options: []),
                      let match = arrayRegex.firstMatch(in: outputText, options: [], range: NSRange(location: 0, length: outputText.utf16.count)),
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
    
    public func analyzeBlackScreenTransition(preFrame: String, blackFrame: String, endFrame: String, tier: GemmaModelTier) async -> (isFailure: Bool, reason: String) {
        let isReady = await MainActor.run { 
            if case .ready = self.state { return true }
            return false
        }
        
        await MainActor.run { self.resetContext() }
        
        guard isReady, let session = self.chatSession else { 
            return (true, "VLM Offline or not ready") 
        }
        
        do {
            session.processing = UserInput.Processing(resize: CGSize(width: 512, height: 512))
            session.generateParameters.maxTokens = 150
            
            let userInput = UserInput(prompt: NativeVLMClient.blackScreenPrompt, images: [preFrame, blackFrame, endFrame].map { .url(URL(fileURLWithPath: $0)) })
            let outputText = try await session.respond(to: NativeVLMClient.blackScreenPrompt, role: .user, images: userInput.images, videos: userInput.videos)
            
            fputs("Black Screen VLM Output: \\(outputText)\\n", stderr)
            
            let lower = outputText.lowercased()
            if lower.contains("\"is_technical_failure\": true") || lower.contains("\"is_technical_failure\":true") || lower.contains("\"is_technical_failure\":true,") {
                return (true, outputText)
            } else if lower.contains("\"is_technical_failure\": false") || lower.contains("\"is_technical_failure\":false") || lower.contains("\"is_technical_failure\":false,") {
                return (false, outputText)
            } else {
                return (true, outputText)
            }
        } catch {
            return (true, "VLM Inference Exception: \\(error.localizedDescription)")
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
