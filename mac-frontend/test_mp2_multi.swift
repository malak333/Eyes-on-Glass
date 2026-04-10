import Foundation
import AVFoundation

var asbd = AudioStreamBasicDescription(
    mSampleRate: 48000.0,
    mFormatID: kAudioFormatMPEGLayer2,
    mFormatFlags: 0,
    mBytesPerPacket: 0,
    mFramesPerPacket: 1152,
    mBytesPerFrame: 0,
    mChannelsPerFrame: 2,
    mBitsPerChannel: 0,
    mReserved: 0
)

var inFormat = AVAudioFormat(streamDescription: &asbd)!
var outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000.0, channels: 2, interleaved: false)!

if let converter = AVAudioConverter(from: inFormat, to: outFormat) {
    let dummyData = Data(repeating: 0xFF, count: 2000)
    
    let inBuffer = AVAudioCompressedBuffer(format: inFormat, packetCapacity: 10, maximumPacketSize: 2000)
    inBuffer.byteLength = UInt32(dummyData.count)
    inBuffer.packetCount = 0 // Wait, what if packet count is 0?
    
    dummyData.withUnsafeBytes { ptr in
        inBuffer.data.copyMemory(from: ptr.baseAddress!, byteCount: dummyData.count)
    }
    
    let pcmBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: 4096)!
    var hasData = true
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
    
    print("Status: \(status.rawValue), Error: \(String(describing: error))")
}
