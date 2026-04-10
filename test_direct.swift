import Foundation
import AVFoundation

let sr = 48000.0
let ch = 2

var engine = AVAudioEngine()
var playerNode = AVAudioPlayerNode()

let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sr, channels: UInt32(ch), interleaved: false)!

engine.attach(playerNode)
engine.connect(playerNode, to: engine.mainMixerNode, format: outFormat)

do {
    try engine.start()
    playerNode.play()
} catch {
    print("Error: \(error)")
}

let pcmBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: 1024)!
pcmBuffer.frameLength = 1024
for i in 0..<1024 {
    pcmBuffer.floatChannelData![0][i] = 1.0
    pcmBuffer.floatChannelData![1][i] = 1.0
}

playerNode.scheduleBuffer(pcmBuffer)

// Now mimic extractVisuals
let frameLength = Int(pcmBuffer.frameLength)
let channels = Int(pcmBuffer.format.channelCount)

var waveform: [Float] = []
let leftChannel = pcmBuffer.floatChannelData![0]
let rightChannel = pcmBuffer.floatChannelData![1]

for i in 0..<100 {
    let idx = i * (1024 / 100)
    let mono = (leftChannel[idx] + rightChannel[idx]) / 2.0
    waveform.append(mono)
}

print("Extracted Waveform elements: \(waveform.count)")
let nonzeros = waveform.filter { abs($0) > 0.0001 }.count
print("Nonzero count: \(nonzeros)")

RunLoop.main.run(until: Date().addingTimeInterval(1.0))
