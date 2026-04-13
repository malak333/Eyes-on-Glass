import Foundation
@testable import EyesOnGlass
import MLXVLM

let group = DispatchGroup()
group.enter()

Task {
    print("Testing MLX load directly...")
    do {
        // Just instantiate a container directly from a local dir if we have one
        let hub = HubApi()
        let dir = try await hub.snapshot(from: Hub.Repo(id: "mlx-community/gemma-4-e4b-it-4bit"))
        print("Model directory: \\(dir)")
        
        let container = try await VLMModelFactory.shared.loadContainer(
            configuration: ModelConfiguration(id: "mlx-community/gemma-4-e4b-it-4bit", tokenizerId: "mlx-community/gemma-4-e4b-it-4bit"),
            modelDirectory: dir
        )
        print("Model container loaded successfully!")
    } catch {
        print("Failed to load: \\(error)")
    }
    group.leave()
}
group.wait()
