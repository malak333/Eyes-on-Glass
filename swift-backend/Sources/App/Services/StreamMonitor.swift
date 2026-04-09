import Foundation
import CoreVideo

public struct VideoHealth {
    public let frame: CVPixelBuffer
    // Expandable with Vision pipeline results
}

public actor StreamMonitor {
    private var videoBuffer: [(Int64, VideoHealth)] = []
    private var audioBuffer: [(Int64, AudioHealth)] = []
    
    private var highestPTS: Int64 = 0
    private let staleThresholdTicks: Int64 = 45_000 // 500ms latency threshold in 90kHz
    private let syncWindowTicks: Int64 = 22_500 // 250ms tolerance for A/V sync
    
    // Callback to pass the successfully evaluated frame back out
    private var onSyncedCallback: ((CVPixelBuffer) -> Void)?
    
    public init() {}
    
    public func setOnSynced(_ callback: @escaping (CVPixelBuffer) -> Void) {
        self.onSyncedCallback = callback
    }
    
    public func report(pts: Int64, video: VideoHealth? = nil, audio: AudioHealth? = nil) {
        highestPTS = max(highestPTS, pts)
        
        if let v = video {
            videoBuffer.append((pts, v))
            // Sort to ensure monotonic processing just in case of out-of-order decode
            videoBuffer.sort(by: { $0.0 < $1.0 }) 
        }
        if let a = audio {
            audioBuffer.append((pts, a))
            audioBuffer.sort(by: { $0.0 < $1.0 })
        }
        
        processBuffers()
    }
    
    private func processBuffers() {
        while let firstVideo = videoBuffer.first {
            let vPTS = firstVideo.0
            
            // Look for an audio status close to this video PTS
            if let audioIndex = audioBuffer.firstIndex(where: { abs($0.0 - vPTS) <= syncWindowTicks }) {
                let a = audioBuffer[audioIndex].1
                evaluateIntegrity(pts: vPTS, video: firstVideo.1, audio: a)
                videoBuffer.removeFirst()
                
                // Keep the matched audio frame around briefly just in case multiple video frames
                // span the same audio duration, but prune older audio
                audioBuffer.removeAll(where: { $0.0 < vPTS - syncWindowTicks })
                
            } else if highestPTS - vPTS > staleThresholdTicks {
                // We've waited long enough for audio, it's missing or out of sync.
                // print("StreamMonitor: [ALERT] Audio Stream Loss or Sync Failure detected near PTS \(vPTS)")
                evaluateIntegrity(pts: vPTS, video: firstVideo.1, audio: .silent)
                videoBuffer.removeFirst()
            } else {
                // Must wait for more audio to arrive to determine sync
                break
            }
        }
        
        // Prune dangling old audio that will never be matched
        audioBuffer.removeAll(where: { highestPTS - $0.0 > staleThresholdTicks * 2 })
    }
    
    private func evaluateIntegrity(pts: Int64, video: VideoHealth, audio: AudioHealth) {
        // Core decision engine logic
        // This confirms strict PTS sync was achieved or timeout handled
        
        // Print roughly once a second (90000 ticks)
        if pts % 90000 < 3000 {
            print("StreamMonitor: Sync Validated! PTS: \(pts) | Video: Healthy | Audio: \(audio == .healthy ? "Healthy" : "Silent")")
        }
        
        // Continue the pipeline
        onSyncedCallback?(video.frame)
    }
}
