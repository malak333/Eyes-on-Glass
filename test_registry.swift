import Foundation
import MLXLMCommon
import MLXVLM

Task {
    await VLMTypeRegistry.shared.registerModelType("gemma4") { data in
        let configuration = try JSONDecoder().decode(Gemma3Configuration.self, from: data)
        return Gemma3(configuration)
    }
    print("Registration successful!")
}
