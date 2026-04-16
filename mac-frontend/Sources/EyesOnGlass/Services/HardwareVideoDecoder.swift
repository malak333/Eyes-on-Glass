import Foundation
import CoreMedia

public protocol HardwareVideoDecoder: AnyObject {
    var decodedFrameCallback: ((CVPixelBuffer, Int64) -> Void)? { get set }
    
    var videoSize: CGSize? { get }
    var videoColor: String? { get }
    var gopSize: Int { get }
    var frameRate: Double { get }
    
    // Injects a continuous bitstream chunk (e.g. NALU or MPEG Sequence/Picture chunk)
    func decode(data: Data, pts: Int64, dts: Int64?)
    
    // Resets parser state and invalidates any active decompression sessions
    func reset()
}
