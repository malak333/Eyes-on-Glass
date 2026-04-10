import Foundation

public enum TSDemuxerEvent {
    case nalUnit(Data, pts: Int64, dts: Int64?)
    case audio(Data, pts: Int64)
    case discontinuity
}

public class TSDemuxer {
    private var buffer = Data()
    private let tsPacketSize = 188
    
    // State for PES accumulation
    private var isGatheringVideoPES = false
    private var isGatheringAudioPES = false
    private var videoStreamBuffer = Data()
    private var audioStreamBuffer = Data()
    
    private var videoContinuityCounter: UInt8?
    private var audioContinuityCounter: UInt8?
    
    private var lockedVideoPID: UInt16? = nil
    private var lockedAudioPID: UInt16? = nil
    
    private var currentVideoPTS: Int64 = 0
    private var currentVideoDTS: Int64? = nil
    private var currentAudioPTS: Int64 = 0
    
    private var currentEvents: [TSDemuxerEvent] = []
    
    public init() {}
    
    public func process(data: Data) -> [TSDemuxerEvent] {
        currentEvents.removeAll(keepingCapacity: true)
        buffer.append(data)
        
        while buffer.count >= tsPacketSize {
            if buffer[buffer.startIndex] != 0x47 {
                if let nextSync = buffer.firstIndex(of: 0x47) {
                    buffer.removeSubrange(buffer.startIndex..<nextSync)
                    continue
                } else {
                    buffer.removeAll()
                    break
                }
            }
            
            let tsPacket = Data([UInt8](buffer.prefix(tsPacketSize)))
            buffer.removeFirst(tsPacketSize)
            
            parseTSPacket(tsPacket)
        }
        return currentEvents
    }
    
    private func parseTSPacket(_ packet: Data) {
        let pusi = (packet[1] & 0x40) != 0
        let pid = (UInt16(packet[1] & 0x1F) << 8) | UInt16(packet[2])
        let adaptationFieldControl = (packet[3] & 0x30) >> 4
        let continuityCounter = packet[3] & 0x0F
        
        if pid == 0x1FFF { return }
        
        checkContinuity(pid: pid, adaptationFieldControl: adaptationFieldControl, continuityCounter: continuityCounter)
        
        var payloadOffset = 4
        if adaptationFieldControl == 2 || adaptationFieldControl == 3 {
            let adaptationLength = Int(packet[4])
            payloadOffset += 1 + adaptationLength
        }
        
        if payloadOffset >= tsPacketSize { return }
        
        let payload = Data(packet.suffix(from: payloadOffset))
        
        if pusi {
            if payload.count > 6 && payload[0] == 0x00 && payload[1] == 0x00 && payload[2] == 0x01 {
                let streamID = payload[3]
                let isVideo = streamID >= 0xE0 && streamID <= 0xEF
                let isAudio = (streamID >= 0xC0 && streamID <= 0xDF) || streamID == 0xBD
                
                if isVideo {
                    if lockedVideoPID == nil {
                        lockedVideoPID = pid
                        print("TSDemuxer: Locked onto Video PID 0x\(String(pid, radix: 16))")
                    }
                    if lockedVideoPID == pid {
                         let oldVideoPTS = currentVideoPTS
                         let oldVideoDTS = currentVideoDTS
                         if let parsedPtsDts = extractPTSAndDTS(from: payload) { 
                             currentVideoPTS = parsedPtsDts.0
                             currentVideoDTS = parsedPtsDts.1
                         }
                         let start = getPESPayloadStart(from: payload)
                         if start < payload.count {
                             let boundary = videoStreamBuffer.endIndex
                             videoStreamBuffer.append(payload.suffix(from: start))
                             extractNALUnits(boundary: boundary, oldPts: oldVideoPTS, oldDts: oldVideoDTS)
                             isGatheringVideoPES = true
                         } else if start == payload.count {
                             isGatheringVideoPES = true
                         }
                    }
                } else if isAudio {
                    if lockedAudioPID == nil {
                        lockedAudioPID = pid
                        print("TSDemuxer: Locked onto Audio PID 0x\(String(pid, radix: 16))")
                    }
                    if lockedAudioPID == pid {
                         if isGatheringAudioPES && !audioStreamBuffer.isEmpty {
                             currentEvents.append(.audio(Data(audioStreamBuffer), pts: currentAudioPTS))
                             audioStreamBuffer.removeAll()
                         }
                         if let parsedPtsDts = extractPTSAndDTS(from: payload) { currentAudioPTS = parsedPtsDts.0 }
                         let start = getPESPayloadStart(from: payload)
                         if start < payload.count {
                             audioStreamBuffer.append(payload.suffix(from: start))
                             extractAudioFrames()
                             isGatheringAudioPES = true
                         } else if start == payload.count {
                             isGatheringAudioPES = true
                         }
                    }
                }
            }
        } else {
            if isGatheringVideoPES && lockedVideoPID == pid {
                let boundary = videoStreamBuffer.endIndex
                videoStreamBuffer.append(payload)
                extractNALUnits(boundary: boundary, oldPts: currentVideoPTS, oldDts: currentVideoDTS)
            } else if isGatheringAudioPES && lockedAudioPID == pid {
                audioStreamBuffer.append(payload)
                extractAudioFrames()
            }
        }
    }
    
    private func checkContinuity(pid: UInt16, adaptationFieldControl: UInt8, continuityCounter: UInt8) {
        if lockedVideoPID == pid {
            if let last = videoContinuityCounter {
                let expected = (last + 1) & 0x0F
                if adaptationFieldControl == 1 || adaptationFieldControl == 3 {
                    if continuityCounter != expected && continuityCounter != last {
                        isGatheringVideoPES = false
                        videoStreamBuffer.removeAll()
                        currentEvents.append(.discontinuity)
                    }
                }
            }
            if adaptationFieldControl == 1 || adaptationFieldControl == 3 {
                videoContinuityCounter = continuityCounter
            }
        } else if lockedAudioPID == pid {
            if let last = audioContinuityCounter {
                let expected = (last + 1) & 0x0F
                if adaptationFieldControl == 1 || adaptationFieldControl == 3 {
                    if continuityCounter != expected && continuityCounter != last {
                        isGatheringAudioPES = false
                        audioStreamBuffer.removeAll()
                        // currentEvents.append(.discontinuity)
                    }
                }
            }
            if adaptationFieldControl == 1 || adaptationFieldControl == 3 {
                audioContinuityCounter = continuityCounter
            }
        }
    }
    
    private func getPESPayloadStart(from payload: Data) -> Int {
        if payload.count > 8 {
            let pesHeaderDataLength = Int(payload[8])
            return 9 + pesHeaderDataLength
        }
        return payload.count
    }
    
    private func extractPTSAndDTS(from payload: Data) -> (Int64, Int64?)? {
        if payload.count > 13 {
            let ptsDtsFlags = (payload[7] & 0xC0) >> 6
            if ptsDtsFlags == 0x2 || ptsDtsFlags == 0x3 {
                let pts1 = Int64(payload[9] & 0x0E) << 29
                let pts2 = Int64(payload[10]) << 22
                let pts3 = Int64(payload[11] & 0xFE) << 14
                let pts4 = Int64(payload[12]) << 7
                let pts5 = Int64(payload[13] & 0xFE) >> 1
                let pts = pts1 | pts2 | pts3 | pts4 | pts5
                
                var dts: Int64? = nil
                if ptsDtsFlags == 0x3 && payload.count > 18 {
                    let dts1 = Int64(payload[14] & 0x0E) << 29
                    let dts2 = Int64(payload[15]) << 22
                    let dts3 = Int64(payload[16] & 0xFE) << 14
                    let dts4 = Int64(payload[17]) << 7
                    let dts5 = Int64(payload[18] & 0xFE) >> 1
                    dts = dts1 | dts2 | dts3 | dts4 | dts5
                }
                
                return (pts, dts)
            }
        }
        return nil
    }
    
    private func extractNALUnits(boundary: Int, oldPts: Int64, oldDts: Int64?) {
        var startOffset = videoStreamBuffer.startIndex
        while startOffset < videoStreamBuffer.endIndex - 4 {
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
                let remaining = videoStreamBuffer.endIndex - startOffset
                let keep = min(3, remaining)
                startOffset = videoStreamBuffer.endIndex - keep
                break
            }
            
            var nextNalStart = -1
            let searchStart = nalStart + prefixLength
            let optimizedSearchStart = max(searchStart, boundary - 4)
            if optimizedSearchStart < (videoStreamBuffer.endIndex - 2) {
                for i in optimizedSearchStart..<(videoStreamBuffer.endIndex - 2) {
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
            
            let ptsToUse = nalStart < boundary ? oldPts : currentVideoPTS
            let dtsToUse = nalStart < boundary ? oldDts : currentVideoDTS
            
            currentEvents.append(.nalUnit(Data(nalUnit), pts: ptsToUse, dts: dtsToUse))
            startOffset = nextNalStart
        }
        
        if startOffset > videoStreamBuffer.startIndex {
            videoStreamBuffer.removeSubrange(videoStreamBuffer.startIndex..<startOffset)
        }
    }
    
    private func extractAudioFrames() {
        if !audioStreamBuffer.isEmpty {
            currentEvents.append(.audio(Data(audioStreamBuffer), pts: currentAudioPTS))
            audioStreamBuffer.removeAll()
        }
    }
    
    public func reset() {
        buffer.removeAll()
        isGatheringVideoPES = false
        isGatheringAudioPES = false
        videoStreamBuffer.removeAll()
        audioStreamBuffer.removeAll()
        videoContinuityCounter = nil
        audioContinuityCounter = nil
        lockedVideoPID = nil
        lockedAudioPID = nil
        currentVideoPTS = 0
        currentVideoDTS = nil
        currentAudioPTS = 0
    }
}
