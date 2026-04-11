import Foundation
import AVFoundation

let path = "/Users/michaelnobile/Antigravity/Eyes-on-Glass/backend/uploads/wpvi-capture.ts"
let data = try! Data(contentsOf: URL(fileURLWithPath: path))

var payloadData = Data()
var foundMP2 = false

let packetSize = 188
for offset in stride(from: 0, to: data.count, by: packetSize) {
    if data[offset] == 0x47 {
        let pid = ((Int(data[offset+1]) & 0x1F) << 8) | Int(data[offset+2])
        if pid == 257 || pid == 0x101 { // Check typical PES PIDs for wpvi
            let hasPayload = (data[offset+3] & 0x10) != 0
            if hasPayload {
                let payloadOffset = offset + 4
                // TS headers have variable adaption length
                let adaptLen = (data[offset+3] & 0x20) != 0 ? Int(data[payloadOffset]) : -1
                let pesStart = adaptLen >= 0 ? payloadOffset + 1 + adaptLen : payloadOffset
                
                if pesStart + 8 < offset + packetSize {
                    if data[pesStart] == 0x00 && data[pesStart+1] == 0x00 && data[pesStart+2] == 0x01 {
                        let streamId = data[pesStart+3]
                        if streamId >= 0xC0 && streamId <= 0xDF {
                            let headerLen = Int(data[pesStart+8])
                            let audioStart = pesStart + 9 + headerLen
                            if audioStart + 2 < offset + packetSize {
                                let b0 = data[audioStart]
                                let b1 = data[audioStart+1]
                                if b0 == 0xFF && (b1 & 0xE0) == 0xE0 {
                                    let remaining = (offset + packetSize) - audioStart
                                    payloadData.append(data[audioStart..<offset+packetSize])
                                    if payloadData.count > 2000 {
                                        foundMP2 = true
                                        break
                                    }
                                }
                            }
                        }
                    } else if payloadData.count > 0 {
                        payloadData.append(data[pesStart..<offset+packetSize])
                        if payloadData.count > 2000 {
                            foundMP2 = true
                            break
                        }
                    }
                }
            }
        }
    }
}

if !foundMP2 {
    print("Could not extract MP2 payload")
    exit(1)
}

print("Extracted MP2 Payload Size: \(payloadData.count)")

// Now mimic AudioDecoder MP2 Setup
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
let converter = AVAudioConverter(from: inFormat, to: outFormat)!

var offset = 0
while offset < payloadData.count - 1 {
    let b0 = payloadData[offset]
    let b1 = payloadData[offset+1]
    
    if b0 == 0xFF && (b1 & 0xE0) == 0xE0 {
        let b2 = payloadData[offset+2]
        let bitrateIndex = Int((b2 & 0xF0) >> 4)
        let sampleRateIndex = Int((b2 & 0x0C) >> 2)
        
        let bitrates = [0, 32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384, 0]
        let sampleRates = [44100, 48000, 32000, 0]
        
        let br = bitrates[bitrateIndex] * 1000
        let sr = sampleRates[sampleRateIndex]
        let padding = (b2 & 0x02) >> 1
        
        if br == 0 || sr == 0 {
            offset += 1
            continue
        }
        
        let frameLength = (144 * br / sr) + Int(padding)
        if offset + frameLength > payloadData.count {
            break
        }
        
        let frameData = payloadData.subdata(in: offset..<offset+frameLength)
        let inBuffer = AVAudioCompressedBuffer(format: inFormat, packetCapacity: 1, maximumPacketSize: frameLength)
        inBuffer.packetCount = 1
        inBuffer.byteLength = UInt32(frameLength)
        frameData.withUnsafeBytes { ptr in
            inBuffer.data.copyMemory(from: ptr.baseAddress!, byteCount: frameLength)
        }
        if let descs = inBuffer.packetDescriptions {
            descs[0].mStartOffset = 0
            descs[0].mDataByteSize = UInt32(frameLength)
            descs[0].mVariableFramesInPacket = 0
        }
        
        let pcmBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: 4096)!
        var hasData = true
        var convertError: NSError? = nil
        
        let status = converter.convert(to: pcmBuffer, error: &convertError) { _, outStatus in
            if hasData {
                outStatus.pointee = .haveData
                hasData = false
                return inBuffer
            } else {
                outStatus.pointee = .noDataNow
                return nil
            }
        }
        
        print("Decoded frame of length \(frameLength) -> Status: \(status.rawValue), PCM frames: \(pcmBuffer.frameLength), Error: \(String(describing: convertError))")
        
        offset += frameLength
    } else {
        offset += 1
    }
}
