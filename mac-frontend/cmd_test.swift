import Foundation
@testable import EyesOnGlass

let service = LiveStreamService.shared
let controller = StreamController.shared

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
exit(nonzero > 0 ? 0 : 1)
