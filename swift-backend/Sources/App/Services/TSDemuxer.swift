import Foundation

public enum TSDemuxerEvent {
    case nalUnit(Data)
    case discontinuity
}

public class TSDemuxer {
    private var buffer = Data()
    private let tsPacketSize = 188
    
    // State for PES accumulation
    private var isGatheringPES = false
    private var videoStreamBuffer = Data()
    private var lastContinuityCounter: UInt8?
    
    // We assume PMT tells us the video PID. For simplicity, we can auto-detect the highest bandwidth stream 
    // or just assume a common PID like 0x0100 (256) or auto-lock onto the first PES stream we find.
    private var lockedVideoPID: UInt16? = nil
    private var currentEvents: [TSDemuxerEvent] = []
    
    public init() {}
    
    public func process(data: Data) -> [TSDemuxerEvent] {
        currentEvents.removeAll(keepingCapacity: true)
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
        return currentEvents
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
                        videoStreamBuffer.removeAll()
                        print("TSDemuxer: Continuity error! Expected \(expected), got \(continuityCounter)")
                        currentEvents.append(.discontinuity)
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
                        // Parse PES header length
                        if payload.count > 8 {
                            let pesHeaderDataLength = Int(payload[8])
                            let pesPayloadStart = 9 + pesHeaderDataLength
                            
                            if pesPayloadStart < payload.count {
                                videoStreamBuffer.append(payload.suffix(from: pesPayloadStart))
                                extractNALUnits()
                                isGatheringPES = true
                                lastContinuityCounter = continuityCounter
                            } else if pesPayloadStart == payload.count {
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
            videoStreamBuffer.append(payload)
            extractNALUnits()
        }
    }
    
    private func extractNALUnits() {
        var startOffset = videoStreamBuffer.startIndex
        while startOffset < videoStreamBuffer.endIndex - 4 {
            // Find 0x00 0x00 0x00 0x01 or 0x00 0x00 0x01
            var nalStart = -1
            var prefixLength = 0
            
            for i in startOffset..<(videoStreamBuffer.endIndex - 2) {
                if i < videoStreamBuffer.endIndex - 3, videoStreamBuffer[i] == 0, videoStreamBuffer[i+1] == 0, videoStreamBuffer[i+2] == 0, videoStreamBuffer[i+3] == 1 {
                    nalStart = i
                    prefixLength = 4
                    break
                }
                if videoStreamBuffer[i] == 0, videoStreamBuffer[i+1] == 0, videoStreamBuffer[i+2] == 1 {
                    nalStart = i
                    prefixLength = 3
                    break
                }
            }
            
            if nalStart == -1 {
                // Keep the last 3 bytes just in case they're part of a split start code
                let remaining = videoStreamBuffer.endIndex - startOffset
                let keep = min(3, remaining)
                startOffset = videoStreamBuffer.endIndex - keep
                break
            }
            
            // Find NEXT nal start
            var nextNalStart = -1
            let searchStart = nalStart + prefixLength
            if searchStart < (videoStreamBuffer.endIndex - 2) {
                for i in searchStart..<(videoStreamBuffer.endIndex - 2) {
                    if i < videoStreamBuffer.endIndex - 3, videoStreamBuffer[i] == 0, videoStreamBuffer[i+1] == 0, videoStreamBuffer[i+2] == 0, videoStreamBuffer[i+3] == 1 {
                        nextNalStart = i
                        break
                    }
                    if videoStreamBuffer[i] == 0, videoStreamBuffer[i+1] == 0, videoStreamBuffer[i+2] == 1 {
                        nextNalStart = i
                        break
                    }
                }
            }
            
            if nextNalStart == -1 {
                startOffset = nalStart
                break
            }
            
            let nalUnit = videoStreamBuffer[nalStart..<nextNalStart]
            
            currentEvents.append(.nalUnit(Data(nalUnit)))
            
            startOffset = nextNalStart
        }
        
        if startOffset > videoStreamBuffer.startIndex {
            videoStreamBuffer.removeSubrange(videoStreamBuffer.startIndex..<startOffset)
        }
    }
    
    public func reset() {
        buffer.removeAll()
        isGatheringPES = false
        videoStreamBuffer.removeAll()
        lastContinuityCounter = nil
        lockedVideoPID = nil
    }
}
