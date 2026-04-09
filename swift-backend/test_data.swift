import Foundation
var buffer = Data([1,2,3,4,5])
buffer.removeFirst(2)
print("startIndex is \(buffer.startIndex)")
let val = buffer[0]
print(val)
