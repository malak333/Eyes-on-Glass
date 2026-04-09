import Foundation

public protocol TSDemuxerDelegate: AnyObject {
    func demuxer(_ demuxer: TSDemuxer, didExtractNALUnit nalUnit: Data)
    func demuxerDidDetectDiscontinuity(_ demuxer: TSDemuxer)
}

public class TSDemuxer {
    public weak var delegate: TSDemuxerDelegate?
    
    private var buffer = Data()
    private let tsPacketSize = 188
    
    // State for PES accumulation
    private var isGatheringPES = false
    private var currentPESBuffer = Data()
    private var lastContinuityCounter: UInt8?
    
    // We assume PMT tells us the video PID. For simplicity, we can auto-detect the highest bandwidth stream 
    // or just assume a common PID like 0x0100 (256) or auto-lock onto the first PES stream we find.
    private var lockedVideoPID: UInt16? = nil
    
    public init() {}
    
    public func process(data: Data) {
        buffer.append(data)
        
        // Find 0x47 sync bytes
        while buffer.count >= tsPacketSize {
            if buffer[buffer.startIndex] != 0x47 {
                // Out of sync, scan for next 0x47
                if let nextSync = buffer.firstIndex(of: 0x47) {
                    buffer.removeSubrange(buffer.startIndex..<nextSync)
                    continue
                } else {
                    buffer.removeAll()
                    break
                }
            }
            
            // We have at least one full TS packet starting with 0x47
            let tsPacket = Data(buffer.prefix(tsPacketSize))
            buffer.removeFirst(tsPacketSize)
            
            parseTSPacket(tsPacket)
        }
    }
    
    private func parseTSPacket(_ packet: Data) {
        let pusi = (packet[1] & 0x40) != 0 // Payload Unit Start Indicator
        let pid = (UInt16(packet[1] & 0x1F) << 8) | UInt16(packet[2])
        let adaptationFieldControl = (packet[3] & 0x30) >> 4
        let continuityCounter = packet[3] & 0x0F
        
        // Skip null packets
        if pid == 0x1FFF { return }
        
        // Check discontinuity on our locked PID
        if lockedVideoPID == pid {
            if let last = lastContinuityCounter {
                let expected = (last + 1) & 0x0F
                if adaptationFieldControl == 1 || adaptationFieldControl == 3 {
                    if continuityCounter != expected && continuityCounter != last {
                        // Continuity error
                        isGatheringPES = false
                        currentPESBuffer.removeAll()
                        print("TSDemuxer: Continuity error! Expected \(expected), got \(continuityCounter)")
                        delegate?.demuxerDidDetectDiscontinuity(self)
                        // Don't log wildly, but reset
                    }
                }
            }
            if adaptationFieldControl == 1 || adaptationFieldControl == 3 {
                lastContinuityCounter = continuityCounter
            }
        }
        
        var payloadOffset = 4
        if adaptationFieldControl == 2 || adaptationFieldControl == 3 {
            let adaptationLength = Int(packet[4])
            payloadOffset += 1 + adaptationLength
        }
        
        if payloadOffset >= tsPacketSize { return }
        
        let payload = Data(packet.suffix(from: payloadOffset))
        
        if pusi {
            // New PES packet, parse if it's video
            if payload.count > 6 && payload[0] == 0x00 && payload[1] == 0x00 && payload[2] == 0x01 {
                let streamID = payload[3]
                // 0xE0 to 0xEF are Video Streams
                if streamID >= 0xE0 && streamID <= 0xEF {
                    if lockedVideoPID == nil {
                        lockedVideoPID = pid
                        print("TSDemuxer: Locked onto Video PID 0x\(String(pid, radix: 16))")
                    }
                    
                    if lockedVideoPID == pid {
                        // Finish previous PES
                        if isGatheringPES {
                            if currentPESBuffer.count > 0 {
                                // print("TSDemuxer: Extracting NAL units from PES length \(currentPESBuffer.count)")
                            }
                            extractNALUnits(from: currentPESBuffer)
                        }
                        
                        // Parse PES header length
                        if payload.count > 8 {
                            let pesHeaderDataLength = Int(payload[8])
                            let pesPayloadStart = 9 + pesHeaderDataLength
                            
                            if pesPayloadStart < payload.count {
                                currentPESBuffer = Data(payload.suffix(from: pesPayloadStart))
                                isGatheringPES = true
                                lastContinuityCounter = continuityCounter
                            } else if pesPayloadStart == payload.count {
                                currentPESBuffer = Data()
                                isGatheringPES = true
                                lastContinuityCounter = continuityCounter
                            } else {
                                print("TSDemuxer: PES Header crosses packet boundary, unhandled! pesPayloadStart: \(pesPayloadStart), payload.count: \(payload.count)")
                            }
                        }
                    }
                }
            }
        } else if isGatheringPES && lockedVideoPID == pid {
            currentPESBuffer.append(payload)
        }
    }
    
    private func extractNALUnits(from pesData: Data) {
        var startOffset = 0
        while startOffset < pesData.count - 4 {
            // Find 0x00 0x00 0x00 0x01 or 0x00 0x00 0x01
            var nalStart = -1
            var prefixLength = 0
            
            for i in startOffset..<(pesData.count - 3) {
                if pesData[i] == 0 && pesData[i+1] == 0 && pesData[i+2] == 1 {
                    nalStart = i
                    prefixLength = 3
                    break
                }
                if pesData[i] == 0 && pesData[i+1] == 0 && pesData[i+2] == 0 && pesData[i+3] == 1 {
                    nalStart = i
                    prefixLength = 4
                    break
                }
            }
            
            if nalStart == -1 { break }
            
            // print("TSDemuxer: Found NAL start at \(nalStart) with prefix \(prefixLength)")
            
            // Find NEXT nal start
            var nextNalStart = pesData.count
            let searchStart = nalStart + prefixLength
            if searchStart < (pesData.count - 3) {
                for i in searchStart..<(pesData.count - 3) {
                    if pesData[i] == 0 && pesData[i+1] == 0 && pesData[i+2] == 1 {
                        nextNalStart = i
                        // check if previous is 0 to make it 0 0 0 1
                        if i > 0 && pesData[i-1] == 0 {
                            nextNalStart = i - 1
                        }
                        break
                    }
                }
            }
            
            let nalUnit = pesData[nalStart..<nextNalStart]
            
            // print("TSDemuxer: Extracted NAL unit length \(nalUnit.count)")
            
            // We pass the start codes so the decoder can reconstruct the CMBlockBuffer properly later.
            // Some decoders want Annex B (with start codes), some want AVCC (Length delimited). 
            // We'll pass the whole thing including start codes and let H264Decoder handle formatting.
            delegate?.demuxer(self, didExtractNALUnit: Data(nalUnit))
            
            startOffset = nextNalStart
        }
    }
    
    public func reset() {
        buffer.removeAll()
        isGatheringPES = false
        currentPESBuffer.removeAll()
        lastContinuityCounter = nil
        lockedVideoPID = nil
    }
}
