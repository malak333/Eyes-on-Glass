import Foundation

let nalPayload: [UInt8] = [0x61, 0x9a, 0x11] // random 
var bitOffset = 8 // Skip NAL header

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

if let first_mb = readUE() {
    print("first_mb: \(first_mb)")
}
if let slice_type = readUE() {
    print("slice_type: \(slice_type)")
}
