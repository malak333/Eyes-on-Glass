import Foundation

public enum AudioHealth {
    case healthy
    case silent // Stub state for mock proxy
}

public protocol AudioDecoderDelegate: AnyObject {
    func decoder(_ decoder: AudioDecoder, didDecodeHealth health: AudioHealth, pts: Int64)
}

public class AudioDecoder {
    public weak var delegate: AudioDecoderDelegate?
    
    public init() {}
    
    public func decode(audioPayload: Data, pts: Int64) {
        // Without full AudioToolbox/Accelerate linkage, we assume 
        // the presence of payload indicates a healthy stream for this prototype
        let health: AudioHealth = audioPayload.isEmpty ? .silent : .healthy
        delegate?.decoder(self, didDecodeHealth: health, pts: pts)
    }
}
