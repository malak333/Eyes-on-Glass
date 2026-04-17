import Foundation

public enum TSDemuxerEvent {
    case videoFrame(codec: VideoCodec, data: Data, pts: Int64, dts: Int64?)
    case audio(Data, pts: Int64)
    case discontinuity
}

public class TSDemuxer {
    private var buffer = Data()
    private var bufferOffset = 0
    private let tsPacketSize = 188
    
    // NAL search codes
    private let nalStartCode = Data([0x00, 0x00, 0x01])
    
    // State for PES accumulation
    private var isGatheringVideoPES = false
    private var isGatheringAudioPES = false
    private var videoStreamBuffer = Data()
    private var audioStreamBuffer = Data()
    
    private var pmtPID: UInt16? = nil
    private var videoCodec: VideoCodec = .unknown
    
    private var videoContinuityCounter: UInt8?
    private var audioContinuityCounter: UInt8?
    
    private var lockedVideoPID: UInt16? = nil
    private var lockedAudioPID: UInt16? = nil
    
    public var currentVideoPID: UInt16? { lockedVideoPID }
    public var currentAudioPID: UInt16? { lockedAudioPID }
    
    // Extracted TS Info
    private var tsID: UInt16? = nil
    private var programID: UInt16? = nil
    private var servicesCount: Int = 0
    private var sdtChannel: String? = nil
    private var sdtProvider: String? = nil
    
    // PCR State
    private var lastPCRBase: UInt64? = nil
    private var lastPCRReceiveTime: TimeInterval? = nil
    private var currentPCRJitter: Double? = nil
    private var currentPCRInterval: Double? = nil
    private var tsClockString: String? = nil
    
    public var currentTsClock: String? { tsClockString }
    public var currentPcrJitter: Double? { currentPCRJitter }
    public var currentPcrInterval: Double? { currentPCRInterval }
    
    public var currentTsID: UInt16? { tsID }
    public var currentProgramID: UInt16? { programID }
    public var currentServicesCount: Int { servicesCount }
    public var currentSdtChannel: String? { sdtChannel }
    public var currentSdtProvider: String? { sdtProvider }
    
    private var currentVideoPTS: Int64 = 0
    private var currentVideoDTS: Int64? = nil
    private var currentAudioPTS: Int64 = 0
    
    private var currentEvents: [TSDemuxerEvent] = []
    
    public init() {}
    
    public func process(data: Data) -> [TSDemuxerEvent] {
        currentEvents.removeAll(keepingCapacity: true)
        buffer.append(data)
        
        while buffer.count - bufferOffset >= tsPacketSize {
            let startIndex = buffer.startIndex.advanced(by: bufferOffset)
            
            if buffer[startIndex] != 0x47 {
                let searchRange = startIndex..<buffer.endIndex
                if let nextSync = buffer.range(of: Data([0x47]), options: [], in: searchRange)?.lowerBound {
                    bufferOffset += buffer.distance(from: startIndex, to: nextSync)
                    continue
                } else {
                    bufferOffset = buffer.count
                    break
                }
            }
            
            let tsPacket = buffer.subdata(in: startIndex..<startIndex.advanced(by: tsPacketSize))
            bufferOffset += tsPacketSize
            
            parseTSPacket(tsPacket)
        }
        
        // Prevent buffer bloat
        if bufferOffset > 512 * 1024 {
            buffer.removeSubrange(0..<bufferOffset)
            bufferOffset = 0
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
            if adaptationLength > 0 && 5 + adaptationLength <= tsPacketSize {
                let flags = packet[5]
                let pcrFlag = (flags & 0x10) != 0
                if pcrFlag && adaptationLength >= 7 {
                    let pcrBase1 = UInt64(packet[6]) << 25
                    let pcrBase2 = UInt64(packet[7]) << 17
                    let pcrBase3 = UInt64(packet[8]) << 9
                    let pcrBase4 = UInt64(packet[9]) << 1
                    let pcrBase5 = UInt64(packet[10] & 0x80) >> 7
                    let pcrBase = pcrBase1 | pcrBase2 | pcrBase3 | pcrBase4 | pcrBase5
                    
                    let currentTime = Date().timeIntervalSince1970
                    let pcrTimeSecs = Double(pcrBase) / 90000.0
                    
                    let totalSeconds = Int(pcrTimeSecs)
                    let hours = totalSeconds / 3600
                    let minutes = (totalSeconds % 3600) / 60
                    let seconds = totalSeconds % 60
                    let milliseconds = Int((pcrTimeSecs - Double(totalSeconds)) * 1000)
                    tsClockString = String(format: "%02d:%02d:%02d.%03d", hours, minutes, seconds, milliseconds)
                    
                    if let lastReceived = lastPCRReceiveTime {
                        let intervalMs = (currentTime - lastReceived) * 1000.0
                        currentPCRInterval = intervalMs
                        
                        if let lastPCR = lastPCRBase {
                            let deltaPCRSecs = Double(pcrBase) / 90000.0 - Double(lastPCR) / 90000.0
                            if deltaPCRSecs > 0 {
                                let jitterMs = abs((currentTime - lastReceived) - deltaPCRSecs) * 1000.0
                                if let existing = currentPCRJitter {
                                    currentPCRJitter = existing * 0.9 + jitterMs * 0.1
                                } else {
                                    currentPCRJitter = jitterMs
                                }
                            }
                        }
                    }
                    
                    lastPCRBase = pcrBase
                    lastPCRReceiveTime = currentTime
                }
            }
            payloadOffset += 1 + adaptationLength
        }
        
        if payloadOffset >= tsPacketSize { return }
        
        let payload = Data(packet.suffix(from: payloadOffset))
        
        if pusi {
            if pid == 0x0000 {
                parsePAT(payload: payload, pusi: pusi)
            } else if pid == pmtPID {
                parsePMT(payload: payload, pusi: pusi)
            } else if pid == 0x0011 {
                parseSDT(payload: payload, pusi: pusi)
            }
            
            if payload.count > 6 && payload[0] == 0x00 && payload[1] == 0x00 && payload[2] == 0x01 {
                let streamID = payload[3]
                let isVideo = streamID >= 0xE0 && streamID <= 0xEF
                var isAudio = (streamID >= 0xC0 && streamID <= 0xDF) || streamID == 0xBD
                
                let start = getPESPayloadStart(from: payload)
                if isAudio && start < payload.count {
                    var hasSync = false
                    for i in start..<payload.count - 1 {
                        let b0 = payload[i]
                        let b1 = payload[i+1]
                        
                        if streamID == 0xBD && b0 == 0x0B && b1 == 0x77 {
                            hasSync = true
                            break
                        }
                        
                        if streamID >= 0xC0 && streamID <= 0xDF {
                            // AAC ADTS or MP2/MP3
                            if b0 == 0xFF && ((b1 & 0xF6) == 0xF0 || (b1 & 0xE0) == 0xE0) {
                                hasSync = true
                                break
                            }
                        }
                    }
                    if !hasSync { isAudio = false }
                }
                
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
                         if start < payload.count {
                             let boundary = videoStreamBuffer.endIndex
                             videoStreamBuffer.append(payload.suffix(from: start))
                             extractVideoSyntaxUnits(boundary: boundary, oldPts: oldVideoPTS, oldDts: oldVideoDTS)
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
                extractVideoSyntaxUnits(boundary: boundary, oldPts: currentVideoPTS, oldDts: currentVideoDTS)
            } else if isGatheringAudioPES && lockedAudioPID == pid {
                audioStreamBuffer.append(payload)
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
    
    private func extractVideoSyntaxUnits(boundary: Int, oldPts: Int64, oldDts: Int64?) {
        var startOffset = videoStreamBuffer.startIndex
        
        while startOffset < videoStreamBuffer.endIndex - 3 {
            let initialSearchRange = startOffset..<videoStreamBuffer.endIndex
            guard let firstRange = videoStreamBuffer.range(of: nalStartCode, options: [], in: initialSearchRange) else {
                break 
            }
            
            var nalStart = firstRange.lowerBound
            var prefixLength = 3
            if nalStart > videoStreamBuffer.startIndex && videoStreamBuffer[nalStart - 1] == 0x00 {
                nalStart = nalStart - 1
                prefixLength = 4
            }
            
            let contentStart = nalStart + prefixLength
            let optimizedSearchStart = max(contentStart, boundary - 4)
            
            if optimizedSearchStart > videoStreamBuffer.endIndex - 3 {
                startOffset = nalStart
                break 
            }
            
            let nextSearchRange = optimizedSearchStart..<videoStreamBuffer.endIndex
            guard let nextRange = videoStreamBuffer.range(of: nalStartCode, options: [], in: nextSearchRange) else {
                startOffset = nalStart
                break
            }
            
            var nextNalStart = nextRange.lowerBound
            if nextNalStart > contentStart && videoStreamBuffer[nextNalStart - 1] == 0x00 {
                nextNalStart = nextNalStart - 1
            }
            
            let ptsToUse = nalStart < boundary ? oldPts : currentVideoPTS
            let dtsToUse = nalStart < boundary ? oldDts : currentVideoDTS
            
            let nalUnit = videoStreamBuffer[nalStart..<nextNalStart]
            currentEvents.append(.videoFrame(codec: videoCodec, data: Data(nalUnit), pts: ptsToUse, dts: dtsToUse))
            
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
    
    private func parsePAT(payload: Data, pusi: Bool) {
        guard pusi, payload.count > 1 else { return }
        let pointer = Int(payload[0])
        let offset = 1 + pointer
        guard offset + 8 < payload.count else { return }
        
        let tableID = payload[offset]
        if tableID == 0x00 { // PAT
            let sectionLength = Int((UInt16(payload[offset+1] & 0x0F) << 8) | UInt16(payload[offset+2]))
            guard offset + 3 + sectionLength <= payload.count else { return }
            
            tsID = (UInt16(payload[offset+3]) << 8) | UInt16(payload[offset+4])
            
            let programsLength = sectionLength - 5 - 4 // minus header and CRC32
            if programsLength > 0 {
                servicesCount = programsLength / 4
                // Extract first valid program ID
                for i in stride(from: offset + 8, to: offset + 8 + programsLength, by: 4) {
                    if i + 3 < payload.count {
                        let pn = (UInt16(payload[i]) << 8) | UInt16(payload[i+1])
                        if pn != 0x0000 {
                            programID = pn
                            pmtPID = ((UInt16(payload[i+2]) & 0x1F) << 8) | UInt16(payload[i+3])
                            break
                        }
                    }
                }
            }
        }
    }
    
    private func parsePMT(payload: Data, pusi: Bool) {
        guard pusi, payload.count > 1 else { return }
        let pointer = Int(payload[0])
        let offset = 1 + pointer
        guard offset + 12 < payload.count else { return }
        
        let tableID = payload[offset]
        if tableID == 0x02 { // PMT
            let sectionLength = Int((UInt16(payload[offset+1] & 0x0F) << 8) | UInt16(payload[offset+2]))
            guard offset + 3 + sectionLength <= payload.count else { return }
            
            let programInfoLength = Int((UInt16(payload[offset+10] & 0x0F) << 8) | UInt16(payload[offset+11]))
            var currentOffset = offset + 12 + programInfoLength
            let endOffset = offset + 3 + sectionLength - 4 // before CRC32
            
            while currentOffset + 4 <= endOffset {
                let streamType = payload[currentOffset]
                let elementaryPID = (UInt16(payload[currentOffset+1] & 0x1F) << 8) | UInt16(payload[currentOffset+2])
                let esInfoLength = Int((UInt16(payload[currentOffset+3] & 0x0F) << 8) | UInt16(payload[currentOffset+4]))
                
                if streamType == 0x1B || streamType == 0x24 { 
                    if videoCodec == .unknown { self.videoCodec = .h264 } 
                    if lockedVideoPID == nil { 
                        lockedVideoPID = elementaryPID 
                        print("TSDemuxer (PMT): Locked onto Video PID 0x\(String(elementaryPID, radix: 16)) as H264/HEVC")
                    }
                } else if streamType == 0x02 {
                    if videoCodec == .unknown { self.videoCodec = .mpeg2 }
                    if lockedVideoPID == nil { 
                        lockedVideoPID = elementaryPID 
                        print("TSDemuxer (PMT): Locked onto Video PID 0x\(String(elementaryPID, radix: 16)) as MPEG-2")
                    }
                } else if [0x81, 0x0F, 0x03, 0x04].contains(streamType) {
                    if lockedAudioPID == nil { 
                        lockedAudioPID = elementaryPID 
                        print("TSDemuxer (PMT): Locked onto Audio PID 0x\(String(elementaryPID, radix: 16))")
                    }
                }
                
                currentOffset += 5 + esInfoLength
            }
        }
    }
    
    private func parseSDT(payload: Data, pusi: Bool) {
        guard pusi, payload.count > 1 else { return }
        let pointer = Int(payload[0])
        let offset = 1 + pointer
        guard offset + 11 < payload.count else { return }
        
        let tableID = payload[offset]
        if tableID == 0x42 || tableID == 0x46 { // Actual TS or Other TS
            let sectionLength = Int((UInt16(payload[offset+1] & 0x0F) << 8) | UInt16(payload[offset+2]))
            guard offset + 3 + sectionLength <= payload.count else { return }
            
            var currentOffset = offset + 11
            let endOffset = offset + 3 + sectionLength - 4 // before CRC32
            
            while currentOffset + 4 < endOffset {
                let descriptorsLoopLength = Int((UInt16(payload[currentOffset+3] & 0x0F) << 8) | UInt16(payload[currentOffset+4]))
                var descOffset = currentOffset + 5
                let descEnd = descOffset + descriptorsLoopLength
                
                while descOffset + 2 <= descEnd && descOffset + 2 <= payload.count {
                    let descriptorTag = payload[descOffset]
                    let descriptorLength = Int(payload[descOffset+1])
                    if descriptorTag == 0x48 && descOffset + 2 + descriptorLength <= descEnd { // Service Descriptor
                        _ = payload[descOffset+2]
                        let providerNameLen = Int(payload[descOffset+3])
                        
                        var nameOffset = descOffset + 4
                        if nameOffset + providerNameLen <= payload.count && providerNameLen > 0 {
                            if let name = String(data: payload[nameOffset..<(nameOffset+providerNameLen)], encoding: .utf8) {
                                sdtProvider = name.trimmingCharacters(in: .controlCharacters)
                            }
                        }
                        
                        nameOffset += providerNameLen
                        if nameOffset < payload.count {
                            let serviceNameLen = Int(payload[nameOffset])
                            nameOffset += 1
                            if nameOffset + serviceNameLen <= payload.count && serviceNameLen > 0 {
                                if let name = String(data: payload[nameOffset..<(nameOffset+serviceNameLen)], encoding: .utf8) {
                                    sdtChannel = name.trimmingCharacters(in: .controlCharacters)
                                }
                            }
                        }
                        break // Parsed service descriptor, done with this service
                    }
                    descOffset += 2 + descriptorLength
                }
                currentOffset += 5 + descriptorsLoopLength
            }
        }
    }
    
    public func reset() {
        buffer.removeAll()
        bufferOffset = 0
        isGatheringVideoPES = false
        isGatheringAudioPES = false
        videoStreamBuffer.removeAll()
        audioStreamBuffer.removeAll()
        videoContinuityCounter = nil
        audioContinuityCounter = nil
        lockedVideoPID = nil
        lockedAudioPID = nil
        pmtPID = nil
        videoCodec = .unknown
        currentVideoPTS = 0
        currentVideoDTS = nil
        currentAudioPTS = 0
        
        tsID = nil
        programID = nil
        servicesCount = 0
        sdtChannel = nil
        sdtProvider = nil
        
        lastPCRBase = nil
        lastPCRReceiveTime = nil
        currentPCRJitter = nil
        currentPCRInterval = nil
        tsClockString = nil
    }
}
