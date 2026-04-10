import Foundation
import AVFoundation

let sr = 48000.0
let ch = 2

var engine = AVAudioEngine()
var playerNode = AVAudioPlayerNode()

let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sr, channels: UInt32(ch), interleaved: false)!

engine.attach(playerNode)
engine.connect(playerNode, to: engine.mainMixerNode, format: outFormat)
try! engine.start()
playerNode.play()

let pcmBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: 1024)!
pcmBuffer.frameLength = 1024
for i in 0..<1024 {
    pcmBuffer.floatChannelData![0][i] = 1.0
    pcmBuffer.floatChannelData![1][i] = 1.0
}

playerNode.scheduleBuffer(pcmBuffer)

let data = pcmBuffer.floatChannelData
print("Float channel data after schedule: \(data != nil)")

RunLoop.main.run(until: Date().addingTimeInterval(1.0))
