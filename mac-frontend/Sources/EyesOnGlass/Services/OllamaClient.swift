import Foundation

struct OllamaClient {
    static let url = "http://localhost:11434/api/generate"
    
    static func analyzeFrame(imagePath: String, model: String) async -> (isSlate: Bool, confidence: Double) {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: imagePath)) else { return (false, 0) }
        let base64 = data.base64EncodedString()
        
        let prompt = "Does this frame appear to be a static slate or holding screen? Reply exclusively in valid JSON with keys 'is_slate' (boolean) and 'confidence' (float between 0.0 and 1.0). No other text."
        
        struct OllamaPayload: Codable {
            let model: String
            let prompt: String
            let stream: Bool
            let images: [String]
            let format: String
        }
        
        let payload = OllamaPayload(model: model, prompt: prompt, stream: false, images: [base64], format: "json")
        
        guard let endpoint = URL(string: url) else { return (false, 0) }
        
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        do {
            request.httpBody = try JSONEncoder().encode(payload)
            let (responseData, _) = try await URLSession.shared.data(for: request)
            
            struct OllamaResponse: Codable {
                let response: String
            }
            
            if let resp = try? JSONDecoder().decode(OllamaResponse.self, from: responseData),
               let innerData = resp.response.data(using: .utf8) {
                
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
