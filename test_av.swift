import AVFoundation
import Foundation

let path = CommandLine.arguments[1]
let url = URL(fileURLWithPath: path)
let asset = AVAsset(url: url)

Task {
    do {
        if let track = try await asset.loadTracks(withMediaType: .audio).first {
            let outputSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
            if reader.canAdd(output) {
                reader.add(output)
                if reader.startReading() {
                    print("Reading buffers...")
                    var count = 0
                    while reader.status == .reading {
                        if let buf = output.copyNextSampleBuffer() {
                            count += 1
                        }
                    }
                    print("Done reading \(count) buffers. Status: \(reader.status.rawValue)")
                }
            }
        }
    } catch {
        print("Error: \(error)")
    }
    Darwin.exit(0)
}

RunLoop.main.run()
