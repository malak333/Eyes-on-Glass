import AVFoundation

let sr = 48000.0
let ch = 3

let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_MPEG_3_0_A)
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

let inFormat = AVAudioFormat(streamDescription: &asbd, channelLayout: layout)!
let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sr, channels: 2, interleaved: false)!

let converter = AVAudioConverter(from: inFormat, to: outFormat)
print("Converter created for downmix? \(converter != nil)")
