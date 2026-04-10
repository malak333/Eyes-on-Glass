import Foundation
import AVFoundation

var asbd = AudioStreamBasicDescription(
    mSampleRate: 48000.0,
    mFormatID: kAudioFormatAC3,
    mFormatFlags: 0,
    mBytesPerPacket: 0,
    mFramesPerPacket: 1536,
    mBytesPerFrame: 0,
    mChannelsPerFrame: 2,
    mBitsPerChannel: 0,
    mReserved: 0
)

var inFormat = AVAudioFormat(streamDescription: &asbd)!
var outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000.0, channels: 2, interleaved: false)!

if let converter = AVAudioConverter(from: inFormat, to: outFormat) {
    let dummyData = Data(repeating: 0x0B, count: 5000)
    
    let inBuffer = AVAudioCompressedBuffer(format: inFormat, packetCapacity: 10, maximumPacketSize: 5000)
    inBuffer.byteLength = UInt32(dummyData.count)
    inBuffer.packetCount = 0
    
    dummyData.withUnsafeBytes { ptr in
        inBuffer.data.copyMemory(from: ptr.baseAddress!, byteCount: dummyData.count)
    }
    
    var hasData = true
    var convertedSamples = 0
    
    while true {
        let pcmBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: 4096)!
        var error: NSError? = nil
        let status = converter.convert(to: pcmBuffer, error: &error) { inNumPackets, outStatus in
            if hasData {
                outStatus.pointee = .haveData
                hasData = false
                return inBuffer
            } else {
                outStatus.pointee = .noDataNow
                return nil
            }
        }
        
        print("Loop Status: \(status.rawValue), error: \(String(describing: error)), len: \(pcmBuffer.frameLength)")
        convertedSamples += Int(pcmBuffer.frameLength)
        
        if status == .error || status == .endOfStream || status == .inputRanDry {
            break
        }
    }
    
    print("Total converted samples: \(convertedSamples)")
}
