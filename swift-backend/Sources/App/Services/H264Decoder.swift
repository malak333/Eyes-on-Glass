import Foundation
import VideoToolbox

public protocol H264DecoderDelegate: AnyObject {
    func decoder(_ decoder: H264Decoder, didDecode frame: CVPixelBuffer, pts: Int64)
}

public class H264Decoder {
    public weak var delegate: H264DecoderDelegate?
    
    private var formatDesc: CMVideoFormatDescription?
    private var decompressionSession: VTDecompressionSession?
    
    private var spsCollection: [Data] = []
    private var ppsCollection: [Data] = []
    private var needsFormatDescUpdate: Bool = false
    private var monotonicDTS: Int64 = 0
    
    private var currentFrameNALs: [Data] = []
    private var currentFramePTS: Int64 = -1
    private var currentFrameDTS: Int64? = nil
    private var isCurrentFrameSync: Bool = false
    
    private let stateLock = NSLock()
    private var needsSessionDrop = false
    private var isWaitingForSync = false
    
    public init() {}
    
    public func decode(nalUnit: Data, pts: Int64, dts: Int64?) {
        var startCodeLength = 0
        if nalUnit.count > 4, nalUnit[0] == 0, nalUnit[1] == 0, nalUnit[2] == 0, nalUnit[3] == 1 {
            startCodeLength = 4
        } else if nalUnit.count > 3, nalUnit[0] == 0, nalUnit[1] == 0, nalUnit[2] == 1 {
            startCodeLength = 3
        }
        
        guard startCodeLength > 0 else { return }
        let nalPayload = [UInt8](nalUnit.suffix(from: startCodeLength))
        guard !nalPayload.isEmpty else { return }
        
        let nalType = nalPayload[0] & 0x1F
        if nalType != 9 {
             print("H264Decoder: Received NAL type \(nalType) (count: \(nalPayload.count)) PTS: \(pts)")
        }
        
        if pts != currentFramePTS {
            if !currentFrameNALs.isEmpty {
                decodeAccumulatedFrame()
                currentFrameNALs.removeAll()
            }
            currentFramePTS = pts
            currentFrameDTS = dts
            isCurrentFrameSync = false
        }
        
        switch nalType {
        case 7:
            let data = Data(nalPayload)
            if !spsCollection.contains(data) {
                spsCollection.append(data)
                needsFormatDescUpdate = true
            }
            isCurrentFrameSync = true
        case 8:
            let data = Data(nalPayload)
            if !ppsCollection.contains(data) {
                ppsCollection.append(data)
                needsFormatDescUpdate = true
            }
            isCurrentFrameSync = true
        case 5:
            isCurrentFrameSync = true
            currentFrameNALs.append(Data(nalPayload))
        case 1:
            var bitOffset = 8
            func readBit() -> Int? {
                let byteIdx = bitOffset / 8
                let bitIdx = 7 - (bitOffset % 8)
                if byteIdx >= nalPayload.count { return nil }
                let bit = (nalPayload[byteIdx] >> bitIdx) & 1
                bitOffset += 1
                return Int(bit)
            }
            func readUE() -> Int? {
                var zeroCount = 0
                while let bit = readBit() {
                    if bit == 1 { break }
                    zeroCount += 1
                }
                if zeroCount == 0 { return 0 }
                var value = 0
                for _ in 0..<zeroCount {
                    guard let bit = readBit() else { return nil }
                    value = (value << 1) | bit
                }
                return (1 << zeroCount) - 1 + value
            }
            
            let _ = readUE()
            if let sliceType = readUE() {
                if sliceType == 2 || sliceType == 7 {
                    isCurrentFrameSync = true
                }
            }
            currentFrameNALs.append(Data(nalPayload))
        case 6:
            currentFrameNALs.append(Data(nalPayload))
        default: break
        }
    }
    
    public func reset() {
        if let session = decompressionSession {
            VTDecompressionSessionInvalidate(session)
            decompressionSession = nil
        }
        monotonicDTS = 0
        currentFrameNALs.removeAll()
        currentFramePTS = -1
        currentFrameDTS = nil
        isCurrentFrameSync = false
        isWaitingForSync = true
    }
    
    private func createFormatDescription() {
        guard !spsCollection.isEmpty else { print("H264Decoder: formatDesc failed - SPS empty"); return }
        guard !ppsCollection.isEmpty else { print("H264Decoder: formatDesc failed - PPS empty"); return }
        let allParamSets = spsCollection + ppsCollection
        let parameterSetSizes = allParamSets.map { $0.count }
        let nsDataArray = allParamSets.map { $0 as NSData }
        let parameterSetPointers = nsDataArray.map { $0.bytes.assumingMemoryBound(to: UInt8.self) }
        
        var newFormatDesc: CMFormatDescription?
        let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
            allocator: kCFAllocatorDefault,
            parameterSetCount: allParamSets.count,
            parameterSetPointers: parameterSetPointers,
            parameterSetSizes: parameterSetSizes,
            nalUnitHeaderLength: 4,
            formatDescriptionOut: &newFormatDesc
        )
        if status == noErr, let format = newFormatDesc {
            self.formatDesc = format
        } else {
            print("H264Decoder: Failed to create format description. Status: \(status)")
        }
    }
    
    private func createDecompressionSession() {
        guard let formatDesc = formatDesc else { return }
        let decoderParameters = [kVTDecompressionPropertyKey_RealTime: kCFBooleanTrue] as CFDictionary
        let destinationPixelBufferAttributes = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA] as CFDictionary
        
        var outputCallback = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: callback,
            decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        
        var newSession: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDesc,
            decoderSpecification: decoderParameters,
            imageBufferAttributes: destinationPixelBufferAttributes,
            outputCallback: &outputCallback,
            decompressionSessionOut: &newSession
        )
        
        if status == noErr, let session = newSession {
            print("H264Decoder: Successfully created VTDecompressionSession")
            self.decompressionSession = session
        } else {
            print("H264Decoder: Failed to create VT session. Status: \(status)")
        }
    }
    
    private func decodeAccumulatedFrame() {
        guard !currentFrameNALs.isEmpty else { 
            print("H264Decoder: Frame empty, dropping (PTS: \(currentFramePTS))")
            return 
        }
        
        let hasSlice = currentFrameNALs.contains { ($0[0] & 0x1F) == 1 || ($0[0] & 0x1F) == 5 }
        guard hasSlice else {
            print("H264Decoder: Skipping submission because no slices present (PTS: \(currentFramePTS))")
            return
        }
        
        stateLock.lock()
        let dropSession = needsSessionDrop
        needsSessionDrop = false
        stateLock.unlock()
        
        if dropSession {
            if let session = decompressionSession {
                print("H264Decoder: Invalidating stuck VTDecompressionSession due to bad data (-8969)")
                VTDecompressionSessionInvalidate(session)
                decompressionSession = nil
            }
            isWaitingForSync = true
        }
        
        if formatDesc == nil || needsFormatDescUpdate {
            print("H264Decoder: Updating format description from SPS/PPS")
            createFormatDescription()
            needsFormatDescUpdate = false
            if decompressionSession == nil {
                isWaitingForSync = true
            }
        }
        
        if decompressionSession == nil && formatDesc != nil {
            if isCurrentFrameSync {
                createDecompressionSession()
                isWaitingForSync = false
            } else {
                print("H264Decoder: Dropping P-Frame because no session and frame is not sync (PTS: \(currentFramePTS))")
                return // Drop P-frames until sync
            }
        }
        
        if isWaitingForSync && !isCurrentFrameSync {
            print("H264Decoder: Dropping P-Frame because isWaitingForSync is true (PTS: \(currentFramePTS))")
            return
        }
        
        guard let formatDesc = formatDesc, let session = decompressionSession else { 
            print("H264Decoder: Dropping frame because session or formatDesc is nil (PTS: \(currentFramePTS))")
            return 
        }
        
        var totalSize = 0
        for nal in currentFrameNALs { totalSize += 4 + nal.count }
        var frameData = Data(capacity: totalSize)
        for nal in currentFrameNALs {
            var length = UInt32(nal.count).bigEndian
            withUnsafeBytes(of: &length) { frameData.append(contentsOf: $0) }
            frameData.append(nal)
        }
        
        var blockBuffer: CMBlockBuffer?
        let status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: frameData.count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: frameData.count, flags: 0, blockBufferOut: &blockBuffer
        )
        guard status == kCMBlockBufferNoErr, let bbuf = blockBuffer else { return }
        
        frameData.withUnsafeBytes { ptr in
            if let base = ptr.baseAddress {
                CMBlockBufferReplaceDataBytes(with: base, blockBuffer: bbuf, offsetIntoDestination: 0, dataLength: frameData.count)
            }
        }
        
        var sampleBuffer: CMSampleBuffer?
        var sampleSizeArray = [totalSize]
        
        let actualDTS: Int64
        if let dts = currentFrameDTS {
            actualDTS = dts
            monotonicDTS = dts + 1
        } else {
            if monotonicDTS == 0 || monotonicDTS >= currentFramePTS {
                monotonicDTS = currentFramePTS - 90000
            }
            actualDTS = monotonicDTS
            monotonicDTS += 3000
        }
        
        let decodeTime = CMTime(value: actualDTS, timescale: 90000)
        let timingInfo = CMSampleTimingInfo(duration: CMTime.invalid, presentationTimeStamp: CMTime(value: currentFramePTS, timescale: 90000), decodeTimeStamp: decodeTime)
        var timingInfoArray = [timingInfo]
        
        let createStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: bbuf, formatDescription: formatDesc,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timingInfoArray,
            sampleSizeEntryCount: 1, sampleSizeArray: &sampleSizeArray, sampleBufferOut: &sampleBuffer
        )
        
        guard createStatus == noErr, let sample = sampleBuffer else { return }
        
        if !isCurrentFrameSync {
            if let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) as NSArray?,
               attachmentsArray.count > 0, let dict = attachmentsArray[0] as? NSMutableDictionary {
                dict[kCMSampleAttachmentKey_NotSync as String] = kCFBooleanTrue
            }
        }
        
        var flagsOut: VTDecodeInfoFlags = []
        let decodeStatus = VTDecompressionSessionDecodeFrame(
            session, sampleBuffer: sample, flags: [._EnableAsynchronousDecompression],
            frameRefcon: nil, infoFlagsOut: &flagsOut
        )
        if isCurrentFrameSync {
            print("H264Decoder: Submitted IDR frame to VT (PTS: \(currentFramePTS), DTS: \(actualDTS))")
        } else {
            print("H264Decoder: Submitted P/B frame to VT (PTS: \(currentFramePTS), DTS: \(actualDTS))")
        }
        
        if decodeStatus != noErr {
            if decodeStatus == kVTVideoDecoderBadDataErr || decodeStatus == -8969 {
                stateLock.lock()
                needsSessionDrop = true
                stateLock.unlock()
            } else {
                print("H264Decoder: VT Decoder Error: \(decodeStatus)")
            }
        }
    }
    
    private let callback: VTDecompressionOutputCallback = {
        decompressionOutputRefCon, sourceFrameRefCon, status, infoFlags, imageBuffer, presentationTimeStamp, presentationDuration in
        
        let decoder = Unmanaged<H264Decoder>.fromOpaque(decompressionOutputRefCon!).takeUnretainedValue()
        
        if status != noErr {
            print("H264Decoder: Callback returned error status \(status)")
            if status == kVTVideoDecoderBadDataErr || status == -8969 {
                decoder.stateLock.lock()
                decoder.needsSessionDrop = true
                decoder.stateLock.unlock()
            }
        }
        
        guard status == noErr, let pixelBuffer = imageBuffer else { return }
        let pts = presentationTimeStamp.value
        print("H264Decoder: VT Callback emitted frame (PTS: \(pts))")
        decoder.delegate?.decoder(decoder, didDecode: pixelBuffer, pts: pts)
    }
}
