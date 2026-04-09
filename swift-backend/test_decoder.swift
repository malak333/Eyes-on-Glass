import Foundation
import CoreVideo
import VideoToolbox

let sourceURL = URL(fileURLWithPath: "/Users/michaelnobile/Antigravity/Eyes-on-Glass/uploads/orioles-10MB.ts")
let tsData = try! Data(contentsOf: sourceURL)

class TestBridge: TSDemuxerDelegate, H264DecoderDelegate {
    var nalUnits: Int = 0
    var frames: Int = 0
    
    func demuxer(_ demuxer: TSDemuxer, didExtractNALUnit nalUnit: Data) {
        nalUnits += 1
        decoder.decode(nalUnit: nalUnit)
    }
    func demuxerDidDetectDiscontinuity(_ demuxer: TSDemuxer) {
        print("Discontinuity")
    }
    func decoder(_ decoder: H264Decoder, didDecode frame: CVPixelBuffer) {
        frames += 1
    }
}

let demuxer = TSDemuxer()
let decoder = H264Decoder()
let bridge = TestBridge()
demuxer.delegate = bridge
decoder.delegate = bridge

// Parse chunk by chunk to simulate stream
let chunkSize = 1316
var offset = 0
while offset < tsData.count {
    let chunkEnd = min(offset + chunkSize, tsData.count)
    let chunk = tsData.subdata(in: offset..<chunkEnd)
    demuxer.process(data: chunk)
    offset = chunkEnd
}

print("Total NALs extracted: \(bridge.nalUnits), Frames Decoded: \(bridge.frames)")
