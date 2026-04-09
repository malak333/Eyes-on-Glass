import Foundation
import VideoToolbox

public protocol H264DecoderDelegate: AnyObject {
    func decoder(_ decoder: H264Decoder, didDecode frame: CVPixelBuffer)
}

public class H264Decoder {
    public weak var delegate: H264DecoderDelegate?
    
    private var formatDesc: CMVideoFormatDescription?
    private var decompressionSession: VTDecompressionSession?
    
    private var sps: [UInt8]?
    private var pps: [UInt8]?
    
    private var lastEmittedTime: TimeInterval = 0
    private let emitInterval: TimeInterval = 1.0 // 1 Frame Per Second
    
    public init() {}
    
    public func decode(nalUnit: Data) {
        // Strip the start code (0x00000001 or 0x000001)
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
        
        switch nalType {
        case 7: // SPS
            // print("H264Decoder: Received SPS length \(nalPayload.count)")
            sps = nalPayload
        case 8: // PPS
            // print("H264Decoder: Received PPS length \(nalPayload.count)")
            pps = nalPayload
        case 5: // IDR
            if formatDesc == nil {
                print("H264Decoder: Creating format description from SPS/PPS")
                createFormatDescription()
            }
            // print("H264Decoder: Decode IDR frame length \(nalPayload.count)")
            decodeFrame(nalPayload: nalPayload)
        case 1: // Non-IDR P/B frame
            // print("H264Decoder: Decode non-IDR frame length \(nalPayload.count)")
            decodeFrame(nalPayload: nalPayload)
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
        sps = nil
        pps = nil
    }
    
    private func createFormatDescription() {
        guard let sps = sps, let pps = pps else { return }
        
        sps.withUnsafeBufferPointer { spsBuf in
            pps.withUnsafeBufferPointer { ppsBuf in
                guard let spsBase = spsBuf.baseAddress, let ppsBase = ppsBuf.baseAddress else { return }
                
                let parameterSetPointers = [spsBase, ppsBase]
                let parameterSetSizes = [sps.count, pps.count]
                
                var newFormatDesc: CMFormatDescription?
                let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: parameterSetPointers,
                    parameterSetSizes: parameterSetSizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &newFormatDesc
                )
                
                if status == noErr, let format = newFormatDesc {
                    self.formatDesc = format
                    createDecompressionSession()
                } else {
                    print("H264Decoder: Failed to create format description. Status: \(status)")
                }
            }
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
    
    private func decodeFrame(nalPayload: [UInt8]) {
        guard let session = decompressionSession else { return }
        
        // Wrap NAL payload inside AVCC length-delimited format
        var bigEndianLength = UInt32(nalPayload.count).bigEndian
        var blockBuffer: CMBlockBuffer?
        
        let lengthSize = MemoryLayout<UInt32>.size
        let totalSize = lengthSize + nalPayload.count
        
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: totalSize,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: totalSize,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        
        guard status == kCMBlockBufferNoErr, let block = blockBuffer else { return }
        
        _ = withUnsafeBytes(of: &bigEndianLength) { lengthPtr in
            CMBlockBufferReplaceDataBytes(with: lengthPtr.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: lengthSize)
        }
        _ = nalPayload.withUnsafeBytes { payloadPtr in
            CMBlockBufferReplaceDataBytes(with: payloadPtr.baseAddress!, blockBuffer: block, offsetIntoDestination: lengthSize, dataLength: nalPayload.count)
        }
        
        var sampleBuffer: CMSampleBuffer?
        var sampleSizeArray = [totalSize]
        
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: formatDesc,
            sampleCount: 1,
            sampleTimingEntryCount: 0,
            sampleTimingArray: nil,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSizeArray,
            sampleBufferOut: &sampleBuffer
        )
        
        guard status == noErr, let sample = sampleBuffer else { return }
        
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
                print("H264Decoder: VT Decoder Bad Data. Expecting glitch until next IDR.")
            } else {
                print("H264Decoder: VT Decoder Error: \(decodeStatus)")
            }
        }
    }
    
    private let callback: VTDecompressionOutputCallback = {
        decompressionOutputRefCon, sourceFrameRefCon, status, infoFlags, imageBuffer, presentationTimeStamp, presentationDuration in
        
        // print("H264Decoder: Output callback with status \(status)")
        guard status == noErr, let pixelBuffer = imageBuffer else { return }
        
        let decoder = Unmanaged<H264Decoder>.fromOpaque(decompressionOutputRefCon!).takeUnretainedValue()
        
        let now = Date().timeIntervalSince1970
        if now - decoder.lastEmittedTime >= decoder.emitInterval {
            // print("H264Decoder: Emitting frame!")
            decoder.lastEmittedTime = now
            decoder.delegate?.decoder(decoder, didDecode: pixelBuffer)
        }
    }
}
