import Foundation
@testable import EyesOnGlass
import Tokenizers

let group = DispatchGroup()
group.enter()

Task {
    do {
        print("Checking tokenizer download...")
        let url = URL(fileURLWithPath: ".cache/hf_gemma4_test")
        // Just mock tokenizing
    } catch {
        print("Error: \(error)")
    }
    group.leave()
}

group.wait()
