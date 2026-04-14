import Foundation
@testable import EyesOnGlass

@MainActor
func runTest() async -> Int {
    let controller = StreamController()
    let service = controller.liveStreamService!

Task {
    await service.startMonitoring(uri: "udp://239.0.0.1:1234", sessionName: "CLI_Test")
    
    // Simulate UI is visible
    controller.isAdvancedInspectorVisible = true
}

RunLoop.main.run(until: Date().addingTimeInterval(3.0))

print("Waveform count: \(controller.audioWaveformData.count)")
let nonzero = controller.audioWaveformData.filter { abs($0) > 0.0001 }.count
print("Waveform active values: \(nonzero)")
Task {
    await service.stopMonitoring()
}
RunLoop.main.run(until: Date().addingTimeInterval(1.0))
return nonzero > 0 ? 0 : 1
}

Task {
    let code = await runTest()
    exit(Int32(code))
}
RunLoop.main.run()
