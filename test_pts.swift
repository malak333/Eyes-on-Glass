import Foundation
import CoreMedia

var timingInfo = CMSampleTimingInfo(
    duration: CMTime.invalid,
    presentationTimeStamp: CMTime(value: Int64(Date().timeIntervalSince1970 * 1000), timescale: 1000),
    decodeTimeStamp: CMTime.invalid
)
print(timingInfo.presentationTimeStamp.value)
