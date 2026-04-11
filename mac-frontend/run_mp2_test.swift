import Foundation
import AVFoundation

let path = "/Users/michaelnobile/Antigravity/Eyes-on-Glass/backend/uploads/wpvi-capture.ts"
guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { fatalError() }

// Very basic demux
var audioPES = Data()
var offset = 0
while offset + 188 <= data.count {
    let packet = data.subdata(in: offset..<offset+188)
    if packet[0] == 0x47 {
        let pid = ((UInt16(packet[1]) & 0x1F) << 8) | UInt16(packet[2])
        if pid == 257 { // approx PID, or just assume first audio PID?
            let pusi = (packet[1] & 0x40) != 0
            let afc = (packet[3] & 0x30) >> 4
            var payloadOffset = 4
            if afc == 2 || afc == 3 {
                payloadOffset += 1 + Int(packet[4])
            }
            if afc == 1 || afc == 3 {
                if payloadOffset < 188 {
                    let payload = packet.subdata(in: payloadOffset..<188)
                    if pusi {
                        let headerLen = payload[8]
                        let start = 9 + Int(headerLen)
                        if start < payload.count {
                            audioPES.append(payload.suffix(from: start))
                        }
                    } else {
                        audioPES.append(payload)
                    }
                }
            }
        }
    }
    offset += 188
    if audioPES.count > 100_000 { break }
}

print("Gathered audio PES bytes: \(audioPES.count)")

var formatInfo = AudioStreamBasicDescription(
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

let inFormat = AVAudioFormat(streamDescription: &formatInfo)!
let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: false)!
guard let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
    fatalError("Failed to create AVAudioConverter")
}

var pcmBufferCount = 0
var readOffset = 0

// Find first FF E0
while readOffset < audioPES.count - 1 {
    if audioPES[readOffset] == 0xFF && (audioPES[readOffset+1] & 0xE0) == 0xE0 {
        break
    }
    readOffset += 1
}

while readOffset + 768 <= audioPES.count {
    let frameData = audioPES.subdata(in: readOffset..<readOffset+768)
    
    let inBuffer = AVAudioCompressedBuffer(format: inFormat, packetCapacity: 1, maximumPacketSize: 768)
    inBuffer.packetCount = 1
    inBuffer.byteLength = 768
    frameData.copyBytes(to: inBuffer.data.bindMemory(to: UInt8.self, capacity: 768), count: 768)
    inBuffer.packetDescriptions?[0].mStartOffset = 0
    inBuffer.packetDescriptions?[0].mDataByteSize = 768
    inBuffer.packetDescriptions?[0].mVariableFramesInPacket = 0
    
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
    
    var error: NSError?
    let pcmBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: 1152)!
    let status = converter.convert(to: pcmBuffer, error: &error, withInputFrom: inputBlock)
    
    if pcmBuffer.frameLength > 0 {
        pcmBufferCount += 1
    }
    
    readOffset += 768
}

print("Successfully converted mp2 frames: \(pcmBufferCount)")

