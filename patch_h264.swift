import Foundation

let path = "./swift-backend/Sources/App/Services/H264Decoder.swift"
var content = try! String(contentsOfFile: path)

let target = """
        var sampleSizeArray = [totalSize]
        
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: formatDesc,
            sampleCount: 1,
            sampleTimingEntryCount: 0,
            sampleTimingArray: nil,
"""

let replacement = """
        var sampleSizeArray = [totalSize]
        
        var timingInfo = CMSampleTimingInfo(
            duration: CMTime.invalid,
            presentationTimeStamp: CMTime(value: Int64(Date().timeIntervalSince1970 * 1000), timescale: 1000),
            decodeTimeStamp: CMTime.invalid
        )
        var timingInfoArray = [timingInfo]
        
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: formatDesc,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timingInfoArray,
"""

content = content.replacingOccurrences(of: target, with: replacement)
try! content.write(toFile: path, atomically: true, encoding: .utf8)
print("Patched.")
