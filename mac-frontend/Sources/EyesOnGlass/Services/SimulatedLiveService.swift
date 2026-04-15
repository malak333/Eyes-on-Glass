import Foundation
import SwiftData

struct SimulatedLiveService {
    @MainActor
    static func streamAndAnalyze(filename: String, baseDirectory: String, streamController: StreamController) async {
        // We add pkt_size=1316 buffer configuration to optimize local streaming stability
        let uri = "udp://239.0.0.1:1234?pkt_size=1316&buffer_size=65535"
        let rawURI = "udp://239.0.0.1:1234"
        let fullPath = "\(baseDirectory)/\(filename)"
        
        fputs("Booting Simulated Live Stream for \(filename) on \(rawURI)\n", stderr)
        
        guard let context = streamController.modelContext else {
            fputs("Error: StreamController lacks modelContext.\n", stderr)
            return
        }
        
        // Start Swift background ingestion
        await streamController.startMonitoring(uri: rawURI, context: context)

        // Give the ingestor binding time to settle
        try? await Task.sleep(nanoseconds: 1_000_000_000)

        // Launch FFmpeg to playback the local file in real-time
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
        process.arguments = [
            "-re",
            "-i", fullPath,
            "-c", "copy",
            "-f", "mpegts",
            uri // Use the URI with packet constraints for sending
        ]
        
        // Suppress massive terminal spam from FFmpeg
        // process.standardOutput = FileHandle.nullDevice
        // process.standardError = FileHandle.nullDevice
        
        do {
            try process.run()
            process.waitUntilExit()
            
            fputs("FFmpeg EOF Reached. Yielding 3 seconds for buffer flush...\n", stderr)
            
            // Wait an additional 3.0 seconds after EOF to allow StreamMonitor packet buffers to fully empty
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            
            while await streamController.liveStreamService?.isStageAVerifying == true {
                fputs("Waiting for VLM completion...\\n", stderr)
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            
        } catch {
            fputs("Failed to run ffmpeg simulation: \(error)\n", stderr)
        }
        
        await streamController.stopMonitoring()
        fputs("Simulated session successfully closed.\n", stderr)
    }
}
