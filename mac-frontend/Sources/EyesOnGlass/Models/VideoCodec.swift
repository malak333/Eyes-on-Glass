import Foundation

public enum VideoCodec: String, CustomStringConvertible {
    case h264 = "h264"
    case mpeg2 = "mpeg2"
    case unknown = "unknown"

    public var description: String {
        switch self {
        case .h264: return "H.264"
        case .mpeg2: return "MPEG-2"
        case .unknown: return "Unknown"
        }
    }
}
