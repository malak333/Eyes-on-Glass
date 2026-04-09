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
    
    public init() {}
    
    public func decode(nalUnit: Data, pts: Int64, dts: Int64?) {
        // Strip the start code (0x00000001 or 0x000001)
        var startCodeLength = 0
        if nalUnit.count > 4, nalUnit[0] == 0, nalUnit[1] == 0, nalUnit[2] == 0, nalUnit[3] == 1 {
            startCodeLength = 4
        } else if nalUnit.count > 3, nalUnit[0] == 0, nalUnit[1] == 0, nalUnit[2] == 1 {
            startCodeLength = 3
        }
        
        guard startCodeLength > 0 else { return }
        
        var nalPayload = [UInt8](nalUnit.suffix(from: startCodeLength))
        
        while let last = nalPayload.last, last == 0 {
            nalPayload.removeLast()
        }
        
        guard !nalPayload.isEmpty else { return }
        
        let nalType = nalPayload[0] & 0x1F
        
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
        case 7: // SPS
            let data = Data(nalPayload)
            if !spsCollection.contains(data) {
                spsCollection.append(data)
                needsFormatDescUpdate = true
            }
        case 8: // PPS
            let data = Data(nalPayload)
            if !ppsCollection.contains(data) {
                ppsCollection.append(data)
                needsFormatDescUpdate = true
            }
        case 5: // IDR slice
            isCurrentFrameSync = true
            currentFrameNALs.append(Data(nalPayload))
        case 1, 6: // Non-IDR slice, SEI
            currentFrameNALs.append(Data(nalPayload))
        default:
            break
        }
    }
    
    public func reset() {
        if let session = decompressionSession {
            VTDecompressionSessionInvalidate(session)
            decompressionSession = nil
        }
        formatDesc = nil
        spsCollection.removeAll()
        ppsCollection.removeAll()
        
        monotonicDTS = 0
        currentFrameNALs.removeAll()
        currentFramePTS = -1
        currentFrameDTS = nil
        isCurrentFrameSync = false
    }
    
    private func createFormatDescription() {
        guard !spsCollection.isEmpty, !ppsCollection.isEmpty else { return }
        
        let allParamSets = spsCollection + ppsCollection
        let parameterSetSizes = allParamSets.map { $0.count }
        
        var dummyData = [Data]()
        for p in allParamSets {
            dummyData.append(p)
        }
        
        // Use withUnsafeBytes for each Data object to get the base address
        // Since we need all pointers available simultaneously for the C API,
        // we map over dummyData and extract pointers. Note: withUnsafeBytes closure
        // scope limits pointer lifetime. To pass an array of pointers safely to a C API
        // without escaping problems, we use NSData bytes.
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
            if decompressionSession == nil {
                createDecompressionSession()
            }
        } else {
            print("H264Decoder: Failed to create format description. Status: \(status)")
        }
    }
    
    private func createDecompressionSession() {
        guard let formatDesc = formatDesc else { return }
        
        let decoderParameters = [
            kVTDecompressionPropertyKey_RealTime: kCFBooleanTrue
        ] as CFDictionary
        
        let destinationPixelBufferAttributes = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA
        ] as CFDictionary
        
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
        guard !currentFrameNALs.isEmpty else { return }
        
        if formatDesc == nil || needsFormatDescUpdate {
            print("H264Decoder: Updating format description from SPS/PPS")
            createFormatDescription()
            needsFormatDescUpdate = false
        }
        guard formatDesc != nil else { return }
        guard let session = decompressionSession else { return }
        
        var totalSize = 0
        for nal in currentFrameNALs {
            totalSize += 4 + nal.count
        }
        
        var frameData = Data(capacity: totalSize)
        for nal in currentFrameNALs {
            var length = UInt32(nal.count).bigEndian
            withUnsafeBytes(of: &length) { frameData.append(contentsOf: $0) }
            frameData.append(nal)
        }
        
        var blockBuffer: CMBlockBuffer?
        let status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: frameData.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: frameData.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == kCMBlockBufferNoErr, let bbuf = blockBuffer else { return }
        
        frameData.withUnsafeBytes { ptr in
            if let base = ptr.baseAddress {
                CMBlockBufferReplaceDataBytes(
                    with: base,
                    blockBuffer: bbuf,
                    offsetIntoDestination: 0,
                    dataLength: frameData.count
                )
            }
        }
        
        var sampleBuffer: CMSampleBuffer?
        var sampleSizeArray = [totalSize]
        
        let actualDTS = currentFrameDTS ?? currentFramePTS
        let decodeTime = CMTime(value: actualDTS, timescale: 90000)
        let timingInfo = CMSampleTimingInfo(
            duration: CMTime.invalid,
            presentationTimeStamp: CMTime(value: currentFramePTS, timescale: 90000),
            decodeTimeStamp: decodeTime
        )
        var timingInfoArray = [timingInfo]
        
        let createStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: bbuf,
            formatDescription: formatDesc,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timingInfoArray,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSizeArray,
            sampleBufferOut: &sampleBuffer
        )
        
        guard createStatus == noErr, let sample = sampleBuffer else { return }
        
        // if !isCurrentFrameSync {
        //     if let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) as? NSArray,
        //        attachmentsArray.count > 0,
        //        let dict = attachmentsArray[0] as? NSMutableDictionary {
        //         dict[kCMSampleAttachmentKey_NotSync as String] = kCFBooleanTrue
        //     }
        // }
        
        print("H264Decoder: Decoding Frame | PTS: \(currentFramePTS) | DTS: \(actualDTS) | Sync: \(isCurrentFrameSync)")
        
        var flagsOut: VTDecodeInfoFlags = []
        let decodeStatus = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sample,
            flags: [._EnableAsynchronousDecompression],
            frameRefcon: nil,
            infoFlagsOut: &flagsOut
        )
        
        if decodeStatus != noErr {
            // Bad data err usually
            if decodeStatus == kVTVideoDecoderBadDataErr {
                // Drop and wait for next IDR
                // print("H264Decoder: VT Decoder Bad Data. Expecting glitch until next IDR.")
            } else {
                print("H264Decoder: VT Decoder Error: \(decodeStatus)")
            }
        }
    }
    
    private let callback: VTDecompressionOutputCallback = {
        decompressionOutputRefCon, sourceFrameRefCon, status, infoFlags, imageBuffer, presentationTimeStamp, presentationDuration in
        
        if status != noErr {
            print("H264Decoder: Callback returned error status \(status)")
        }
        
        guard status == noErr, let pixelBuffer = imageBuffer else { 
            if imageBuffer == nil && status == noErr {
                print("H264Decoder: Callback returned no error but imageBuffer is nil")
            }
            return 
        }
        
        let decoder = Unmanaged<H264Decoder>.fromOpaque(decompressionOutputRefCon!).takeUnretainedValue()
        let pts = presentationTimeStamp.value
        
        decoder.delegate?.decoder(decoder, didDecode: pixelBuffer, pts: pts)
    }
}
