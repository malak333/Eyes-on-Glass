import Foundation
import SwiftData
@testable import EyesOnGlass

@MainActor
func testMPEG2() async {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try! ModelContainer(for: VideoLog.self, configurations: config)
    
    let ctrl = StreamController()
    ctrl.modelContext = container.mainContext
    
    let baseDirectory = "/Users/michaelnobile/Video Assets"
    let filename = "CC4Sencore.ts"
    
    print("Testing \(filename)...")
    await SimulatedLiveService.streamAndAnalyze(filename: filename, baseDirectory: baseDirectory, streamController: ctrl)
    
    print("Test finished.")
    exit(0)
}

Task {
    await testMPEG2()
}

RunLoop.main.run()
