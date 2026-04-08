import Foundation
import Vapor

struct OllamaClient {
    static let url = "http://localhost:11434/api/generate"
    
    static func analyzeFrame(client: Client, imagePath: String, model: String) async -> (isSlate: Bool, confidence: Double) {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: imagePath)) else { return (false, 0) }
        let base64 = data.base64EncodedString()
        
        let prompt = "Does this frame appear to be a static slate or holding screen? Reply exclusively in valid JSON with keys 'is_slate' (boolean) and 'confidence' (float between 0.0 and 1.0). No other text."
        
        struct OllamaPayload: Content {
            let model: String
            let prompt: String
            let stream: Bool
            let images: [String]
            let format: String
        }
        
        let payload = OllamaPayload(model: model, prompt: prompt, stream: false, images: [base64], format: "json")
        
        do {
            let response = try await client.post(URI(string: url)) { req in
                try req.content.encode(payload)
            }
            
            struct OllamaResponse: Content {
                let response: String
            }
            
            if let resp = try? response.content.decode(OllamaResponse.self),
               let innerData = resp.response.data(using: String.Encoding.utf8) {
                
                struct LLMResult: Decodable {
                    let is_slate: Bool
                    let confidence: Double
                }
                
                if let result = try? JSONDecoder().decode(LLMResult.self, from: innerData) {
                    return (result.is_slate, result.confidence)
                }
            }
        } catch {
            return (false, 0)
        }
        
        return (false, 0)
    }
}
