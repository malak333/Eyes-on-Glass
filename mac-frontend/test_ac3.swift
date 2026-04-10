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
    print("Successfully created AVAudioConverter for AC3!")
} else {
    print("FAILED to create AVAudioConverter for AC3")
}
