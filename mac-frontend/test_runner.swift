import Foundation
import VideoToolbox

let sps = Data([0x67, 0x4d, 0x40, 0x1f, 0xec, 0xa0, 0x28, 0x02, 0xdd, 0x80, 0x88, 0x00, 0x00, 0x03, 0x00, 0x08, 0x00, 0x00, 0x03, 0x01, 0x94, 0x78, 0xc1, 0x8c, 0xb0])
let pps = Data([0x68, 0xeb, 0xec, 0xb2, 0x2c])
let allParamSets = [sps, pps]
let parameterSetSizes = allParamSets.map { $0.count }
let parameterSetPointers = allParamSets.map { ($0 as NSData).bytes.assumingMemoryBound(to: UInt8.self) }

var newFormatDesc: CMFormatDescription?
let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
    allocator: kCFAllocatorDefault,
    parameterSetCount: allParamSets.count,
    parameterSetPointers: parameterSetPointers,
    parameterSetSizes: parameterSetSizes,
    nalUnitHeaderLength: 4,
    formatDescriptionOut: &newFormatDesc
)

print("Status: \(status)")
if let format = newFormatDesc {
    print("Success: \(format)")
} else {
    print("Fail")
}
