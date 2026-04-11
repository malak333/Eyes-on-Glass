import SwiftUI

fputs("!! BOOT SEQUENCE STARTED !!\n", stderr)
fputs("ANALYSIS_CLI: \(ProcessInfo.processInfo.environment["ANALYSIS_CLI"] ?? "nil")\n", stderr)
fputs("ARGS: \(ProcessInfo.processInfo.arguments)\n", stderr)

if ProcessInfo.processInfo.environment["ANALYSIS_CLI"] == "true" || ProcessInfo.processInfo.arguments.contains("--cli") {
    fputs("Detected CLI flag. Launching BatteryTestingCLI headless mode...\n", stderr)
    
    Task {
        await BatteryTestingCLI.run()
        exit(0)
    }
    
    RunLoop.main.run()
} else {
    // Standard execution of the Native SwiftUI App
    EyesOnGlassApp.main()
}
