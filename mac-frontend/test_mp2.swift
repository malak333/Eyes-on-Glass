import Foundation
import AVFoundation

let mpeg1Layer2Bitrates = [0, 32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384, 0]
let mpeg1SampleRates = [44100, 48000, 32000, 0]

print("kAudioFormatMPEGLayer2: \(kAudioFormatMPEGLayer2)")
print("kAudioFormatAC3: \(kAudioFormatAC3)")

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
    print("Successfully created AVAudioConverter for MP2!")
} else {
    print("FAILED to create AVAudioConverter for MP2")
}
