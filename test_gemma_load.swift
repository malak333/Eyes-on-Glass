import Foundation
@testable import EyesOnGlass

let group = DispatchGroup()
group.enter()

Task {
    print("Preparing model...")
    await NativeVLMClient.shared.prepareModel(tier: .e2b, token: "hf_test_token")
    
    // Wait a brief moment to see if state changes to error
    try? await Task.sleep(nanoseconds: 2_000_000_000)
    
    await MainActor.run {
        print("Final state: \(NativeVLMClient.shared.state)")
    }
    group.leave()
}

group.wait()
