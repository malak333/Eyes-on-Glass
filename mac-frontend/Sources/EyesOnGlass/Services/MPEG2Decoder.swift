import Foundation
import VideoToolbox

public class MPEG2Decoder: HardwareVideoDecoder {
    public var decodedFrameCallback: ((CVPixelBuffer, Int64) -> Void)?
    
    public var videoSize: CGSize? {
        guard let formatDesc = formatDesc else { return nil }
        let dimensions = CMVideoFormatDescriptionGetDimensions(formatDesc)
        return CGSize(width: CGFloat(dimensions.width), height: CGFloat(dimensions.height))
    }
    
    public var videoColor: String? { return "ITU-R BT.709" } // Default approximation
    public var gopSize: Int { return 15 } // Approximation for MPEG-2
    public var frameRate: Double { return 29.97 } // Default
    
    private var formatDesc: CMVideoFormatDescription?
    private var decompressionSession: VTDecompressionSession?
    
    private var width: Int32 = 0
    private var height: Int32 = 0
    
    private var sessionActive = false
    private var sessionInitErrorCount = 0
    
    private var currentFrameData = Data()
    private var currentFramePTS: Int64 = -1
    private var currentFrameDTS: Int64? = nil
    
    private var currentFrameHasSlices = false
    private var lastSequenceHeader: Data?
    
    public init() {}
    
    public func decode(data: Data, pts: Int64, dts: Int64?) {
        guard data.count >= 4 else { return }
        
        let startCodeType = data[3]
        
        // Check if this NAL unit indicates the start of a new access unit
        // 0xB3: Sequence Header, 0xB8: GOP Header, 0x00: Picture Header
        let isNewHeader = (startCodeType == 0xB3 || startCodeType == 0xB8 || startCodeType == 0x00)
        
        // If we see a new header AND we already accumulated slices for the current frame, it's time to flush!
        if isNewHeader && currentFrameHasSlices {
            if !currentFrameData.isEmpty {
                decodeAccumulatedFrame()
                currentFrameData.removeAll(keepingCapacity: true)
                currentFrameHasSlices = false
            }
        }
        
        // Track if we've received slice data for the current frame (0x01 through 0xAF)
        if startCodeType >= 0x01 && startCodeType <= 0xAF {
            currentFrameHasSlices = true
        }

        // Update PTS/DTS only if a new PES explicit timestamp is provided AND we are starting a new frame buffer
        // Or if it's the first frame
        if pts != currentFramePTS && currentFrameData.isEmpty {
            currentFramePTS = pts
            currentFrameDTS = dts
        } else if currentFrameData.isEmpty {
            // Extrapolate PTS linearly by ~1 frame duration (3003 ticks for 29.97fps) if no new PTS is available
            // This prevents identical VT timestamps which can confuse the decoder queue
            currentFramePTS += Int64(90000.0 / frameRate)
            if let d = currentFrameDTS { currentFrameDTS = d + Int64(90000.0 / frameRate) }
        }
        
        currentFrameData.append(data)
    }
    
    private func decodeAccumulatedFrame() {
        var data = currentFrameData
        let pts = currentFramePTS
        let dts = currentFrameDTS
        
        var foundSequenceHeader = false
        let scanLimit = min(data.count - 3, 2048)
        var sequenceHeaderEndIndex: Int? = nil
        
        if scanLimit > 0 {
            for i in 0..<scanLimit {
                if data[i] == 0x00 && data[i+1] == 0x00 && data[i+2] == 0x01 && data[i+3] == 0xB3 {
                    foundSequenceHeader = true
                    // Extract Sequence Header and any extensions before GOP (0xB8) or Picture (0x00)
                    for j in (i+4)..<(data.count-3) {
                        if data[j] == 0x00 && data[j+1] == 0x00 && data[j+2] == 0x01 {
                            let nextCode = data[j+3]
                            if nextCode == 0x00 || nextCode == 0xB8 { // Picture Header or GOP Header
                                sequenceHeaderEndIndex = j
                                break
                            }
                        }
                    }
                    if let endIndex = sequenceHeaderEndIndex {
                        self.lastSequenceHeader = data.subdata(in: i..<endIndex)
                    } else {
                        self.lastSequenceHeader = data.subdata(in: i..<data.count)
                    }
                    break
                }
            }
        }
        
        // P/B frames do not naturally carry the sequence metadata
        if !foundSequenceHeader, let header = lastSequenceHeader {
            var prependedData = header
            prependedData.append(data)
            data = prependedData
        }
        
        // Look for Sequence Header to construct Format Description if not active
        if !sessionActive || formatDesc == nil {
            if let (w, h) = extractDimensions(from: data) {
                if width != w || height != h {
                    width = w
                    height = h
                    if !createDecompressionSession() {
                        print("MPEG2Decoder: Failed to start session for \(w)x\(h)")
                        return
                    }
                }
            } else if !sessionActive {
                // Cant decode until we see a sequence header to get dimensions
                return
            }
        }
        
        // Ensure the payload actually contains visual slice data.
        // Standalone sequence headers (metadata only) will crash VideoToolbox with -12909.
        if !currentFrameHasSlices {
            return
        }
        
        submitToDecoder(data: data, pts: pts, dts: dts)
    }
    
    private func extractDimensions(from data: Data) -> (Int32, Int32)? {
        // Search for 00 00 01 B3 (Sequence Header)
        // We only scan the first few hundred bytes to be efficient
        let scanLimit = min(data.count - 7, 2048)
        for i in 0..<scanLimit {
            if data[i] == 0x00 && data[i+1] == 0x00 && data[i+2] == 0x01 && data[i+3] == 0xB3 {
                let b4 = UInt16(data[i+4])
                let b5 = UInt16(data[i+5])
                let b6 = UInt16(data[i+6])
                
                let w = Int32((b4 << 4) | (b5 >> 4))
                let h = Int32(((b5 & 0x0F) << 8) | b6)
                
                if w > 0 && h > 0 {
                    return (w, h)
                }
            }
        }
        return nil
    }
    
    private func createDecompressionSession() -> Bool {
        if let session = decompressionSession {
            VTDecompressionSessionInvalidate(session)
            decompressionSession = nil
        }
        
        // Ensure valid dimensions
        guard width > 0 && height > 0 else { return false }
        
        let extensions: [String: Any] = [:]
        
        var format: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCMVideoCodecType_MPEG2Video,
            width: width,
            height: height,
            extensions: extensions as CFDictionary,
            formatDescriptionOut: &format
        )
        
        guard status == noErr, let formatDescResult = format else {
            print("MPEG2Decoder: CMVideoFormatDescriptionCreate failed with status \(status)")
            return false
        }
        
        self.formatDesc = formatDescResult
        
        let decoderSpecification: [String: Any] = [:]
        let destinationImageBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
        
        // Using closure-based decoding, no outputCallback struct needed
        var session: VTDecompressionSession?
        let vtStatus = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDescResult,
            decoderSpecification: decoderSpecification as CFDictionary,
            imageBufferAttributes: destinationImageBufferAttributes as CFDictionary,
            outputCallback: nil,
            decompressionSessionOut: &session
        )
        
        guard vtStatus == noErr, let newSession = session else {
            print("MPEG2Decoder: VTDecompressionSessionCreate failed with status \(vtStatus)")
            return false
        }
        
        if !VTDecompressionSessionCanAcceptFormatDescription(newSession, formatDescription: formatDescResult) {
            print("MPEG2Decoder: Hardware decoder rejected the MPEG-2 format description. Unsupported on this device.")
            VTDecompressionSessionInvalidate(newSession)
            return false
        }
        
        self.decompressionSession = newSession
        self.sessionActive = true
        self.sessionInitErrorCount = 0
        
        print("MPEG2Decoder: Initialized successfully for \(width)x\(height)")
        return true
    }
    
    private func submitToDecoder(data: Data, pts: Int64, dts: Int64?) {
        guard let session = decompressionSession, let format = formatDesc else { return }
        
        var blockBuffer: CMBlockBuffer?
        var status = data.withUnsafeBytes { ptr in
            guard let baseAddress = ptr.baseAddress else { return kCMBlockBufferNoErr }
            return CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: nil, // Let it allocate
                blockLength: data.count,
                blockAllocator: kCFAllocatorDefault,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: data.count,
                flags: 0,
                blockBufferOut: &blockBuffer
            )
        }
        
        if status == noErr, let blockBuffer = blockBuffer {
            status = data.withUnsafeBytes { ptr in
                guard let baseAddress = ptr.baseAddress else { return kCMBlockBufferNoErr }
                return CMBlockBufferReplaceDataBytes(
                    with: baseAddress,
                    blockBuffer: blockBuffer,
                    offsetIntoDestination: 0,
                    dataLength: data.count
                )
            }
        }
        
        guard status == noErr, let validBlockBuffer = blockBuffer else {
            print("MPEG2Decoder: Failed to create block buffer")
            return
        }
        
        var sampleBuffer: CMSampleBuffer?
        var timingInfo = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(value: pts, timescale: 90000),
            decodeTimeStamp: dts != nil ? CMTime(value: dts!, timescale: 90000) : .invalid
        )
        
        var sampleSizeArray = [data.count]
        
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: validBlockBuffer,
            formatDescription: format,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timingInfo,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSizeArray,
            sampleBufferOut: &sampleBuffer
        )
        
        guard status == noErr, let validSampleBuffer = sampleBuffer else {
            print("MPEG2Decoder: Failed to create sample buffer")
            return
        }
        
        var infoFlagsOut: VTDecodeInfoFlags = []
        
        let decodeStatus = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: validSampleBuffer,
            flags: [._EnableAsynchronousDecompression],
            infoFlagsOut: &infoFlagsOut
        ) { [weak self] (status: OSStatus, infoFlags: VTDecodeInfoFlags, imageBuffer: CVImageBuffer?, _: [CMTaggedBuffer]?, presentationTimeStamp: CMTime, presentationDuration: CMTime) in
            if status == noErr, let pixelBuffer = imageBuffer {
                self?.decodedFrameCallback?(pixelBuffer, presentationTimeStamp.value)
            }
        }
    }
    
    public func reset() {
        if let session = decompressionSession {
            VTDecompressionSessionInvalidate(session)
        }
        decompressionSession = nil
        formatDesc = nil
        sessionActive = false
        width = 0
        height = 0
        currentFrameData.removeAll(keepingCapacity: true)
        currentFrameHasSlices = false
        currentFramePTS = -1
        currentFrameDTS = nil
        lastSequenceHeader = nil
    }
}


