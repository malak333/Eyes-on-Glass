import Foundation

let payload = Data([0x0B, 0x77, 0x01, 0x02, 0x0B, 0x77, 0x05])
let offset = 0
var nextSync = offset + 2

while nextSync < payload.count - 1 {
    if payload[nextSync] == 0x0B && payload[nextSync+1] == 0x77 {
        break
    }
    nextSync += 1
}

let frameLength = nextSync - offset
print("frameLength: \(frameLength)")
