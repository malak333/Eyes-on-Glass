import Foundation
import CoreMedia

let demuxer = TSDemuxer()
let decoder = AudioDecoder()
let testFile = "/Users/michaelnobile/Antigravity/Eyes-on-Glass/test_assets/CIRCLE-AAC-mb-noise-bars.ts"

guard let data = try? Data(contentsOf: URL(fileURLWithPath: testFile)) else {
    print("Cannot read file")
    exit(1)
}

class Delegate: AudioDecoderDelegate {
    var detectedVisuals = false
    func decoder(_ decoder: AudioDecoder, didDecodeHealth health: AudioHealth, pts: Int64) { }
    func decoder(_ decoder: AudioDecoder, didDecodeVisuals waveform: [Float], vectorscope: [CGPoint], phase: [Float], levels: [Float]) {
        self.detectedVisuals = true
        print("Got visuals! Levels: \(levels)")
    }
}

let delegate = Delegate()
decoder.delegate = delegate

let events = demuxer.process(data: data)
for event in events {
    if case .audio(let payload, let pts) = event {
        decoder.decode(audioPayload: payload, pts: pts)
        if delegate.detectedVisuals { break }
    }
}
print("Done. Visuals detected: \(delegate.detectedVisuals)")
