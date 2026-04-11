import SwiftUI
import SwiftData

struct EyesOnGlassApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(for: VideoLog.self)
        .windowStyle(.hiddenTitleBar) // Premium glassmorphic edge-to-edge frame
    }
}
