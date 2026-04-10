import Foundation
import AVFoundation

let path = "/Users/michaelnobile/Antigravity/Eyes-on-Glass/backend/uploads/CC4Sencore.ts"
let data = try! Data(contentsOf: URL(fileURLWithPath: path))

// Extract first AC-3 payload
var foundAC3 = false
let packetSize = 188
var payloadData = Data()

for offset in stride(from: 0, to: data.count, by: packetSize) {
    if data[offset] == 0x47 {
        let pid = ((Int(data[offset+1]) & 0x1F) << 8) | Int(data[offset+2])
        if pid == 0x31 || pid == 0x32 || pid == 0x33 || pid == 0x1100 { // Check common PIDs
            let hasPayload = (data[offset+3] & 0x10) != 0
            if hasPayload {
                let payloadOffset = offset + 4
                if data[payloadOffset] == 0x00 && data[payloadOffset+1] == 0x00 && data[payloadOffset+2] == 0x01 {
                    let streamId = data[payloadOffset+3]
                    if streamId >= 0xC0 && streamId <= 0xDF || streamId == 0xBD {
                        let headerLen = Int(data[payloadOffset+8])
                        let pesPayloadOffset = payloadOffset + 9 + headerLen
                        if pesPayloadOffset < offset + packetSize {
                            let pl = data[pesPayloadOffset..<offset+packetSize]
                            if pl.count >= 2 && pl[pl.startIndex] == 0x0B && pl[pl.startIndex+1] == 0x77 {
                                payloadData = Data(pl)
                                foundAC3 = true
                                break
                            }
                        }
                    }
                }
            }
        }
    }
}

guard foundAC3 else {
    print("Could not find AC-3 payload in CC4Sencore.ts")
    exit(1)
}

print("Found AC-3 payload of size \(payloadData.count)")

var asbd = AudioStreamBasicDescription(
    mSampleRate: 48000.0,
    mFormatID: kAudioFormatAC3,
    mFormatFlags: 0,
    mBytesPerPacket: 0,
    mFramesPerPacket: 1536,
    mBytesPerFrame: 0,
    mChannelsPerFrame: 2, // or 6?
    mBitsPerChannel: 0,
    mReserved: 0
)

var inFormat = AVAudioFormat(streamDescription: &asbd)!
var outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000.0, channels: 2, interleaved: false)!
let converter = AVAudioConverter(from: inFormat, to: outFormat)!

let inBuffer = AVAudioCompressedBuffer(format: inFormat, packetCapacity: 1, maximumPacketSize: payloadData.count)
inBuffer.packetCount = 1
inBuffer.byteLength = UInt32(payloadData.count)
payloadData.withUnsafeBytes { ptr in
    inBuffer.data.copyMemory(from: ptr.baseAddress!, byteCount: payloadData.count)
}
if let descs = inBuffer.packetDescriptions {
    descs[0].mStartOffset = 0
    descs[0].mDataByteSize = UInt32(payloadData.count)
    descs[0].mVariableFramesInPacket = 0
}

let pcmBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: 4096)!
var hasData = true
var error: NSError? = nil

let status = converter.convert(to: pcmBuffer, error: &error) { _, outStatus in
    if hasData {
        outStatus.pointee = .haveData
        hasData = false
        return inBuffer
    } else {
        outStatus.pointee = .noDataNow
        return nil
    }
}
print("Status: \(status.rawValue), Error: \(String(describing: error)), Length: \(pcmBuffer.frameLength)")
