import Foundation
import Swift
import Accelerate
import AVFoundation

let sr = 48000.0
let ch = 2

var asbd = AudioStreamBasicDescription(
    mSampleRate: sr,
    mFormatID: kAudioFormatMPEG4AAC,
    mFormatFlags: 0,
    mBytesPerPacket: 0,
    mFramesPerPacket: 1024,
    mBytesPerFrame: 0,
    mChannelsPerFrame: UInt32(ch),
    mBitsPerChannel: 0,
    mReserved: 0
)

guard let inFormat = AVAudioFormat(streamDescription: &asbd) else { fatalError() }
guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sr, channels: UInt32(ch), interleaved: false) else { fatalError() }

let converter = AVAudioConverter(from: inFormat, to: outFormat)!

var engine = AVAudioEngine()
var playerNode = AVAudioPlayerNode()
engine.attach(playerNode)
engine.connect(playerNode, to: engine.mainMixerNode, format: outFormat)
try! engine.start()
playerNode.play()

// Create a dummy AAC ADTS frame. Since we don't have a real one, let's just make a valid ADTS header + zeros.
// Note: AVAudioConverter will likely fail to decode zeros and return an error.
let mockADTS: [UInt8] = [0xFF, 0xF1, 0x50, 0x80, 0x07, 0xE0, 0xFC, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
let payload = Data(mockADTS)

let inBuffer = AVAudioCompressedBuffer(format: inFormat, packetCapacity: 1, maximumPacketSize: payload.count)
inBuffer.packetCount = 1
inBuffer.byteLength = UInt32(payload.count)
payload.withUnsafeBytes { ptr in
    inBuffer.data.copyMemory(from: ptr.baseAddress!, byteCount: payload.count)
}
inBuffer.packetDescriptions?[0].mStartOffset = 0
inBuffer.packetDescriptions?[0].mDataByteSize = UInt32(payload.count)
inBuffer.packetDescriptions?[0].mVariableFramesInPacket = 0

let pcmBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: 1024)!
var error: NSError? = nil

var hasData = true
let inputBlock: AVAudioConverterInputBlock = { inNumPackets, outStatus in
    if hasData {
        outStatus.pointee = .haveData
        hasData = false
        return inBuffer
    } else {
        outStatus.pointee = .noDataNow
        return nil
    }
}

let status = converter.convert(to: pcmBuffer, error: &error, withInputFrom: inputBlock)
print("Convert status: \(status.rawValue)")
if let error = error { print("Convert error: \(error)") }

print("PCM Buffer FrameLength: \(pcmBuffer.frameLength)")
playerNode.scheduleBuffer(pcmBuffer)
print("FloatChannelData exists? \(pcmBuffer.floatChannelData != nil)")
