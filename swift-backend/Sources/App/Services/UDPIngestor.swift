import Foundation
import CoreVideo

public actor UDPIngestor {
    private var socketFD: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var isActive = false
    
    // Pipeline components
    private let demuxer = TSDemuxer()
    private let videoDecoder = H264Decoder()
    private let audioDecoder = AudioDecoder()
    private let streamMonitor = StreamMonitor()
    
    // Timers
    private var lastPacketTime: TimeInterval = 0
    private var heartbeatTask: Task<Void, Never>?
    private var processingTask: Task<Void, Never>?
    private var streamContinuation: AsyncStream<Data>.Continuation?
    
    // Callback for LiveStreamService
    private var onFrameCallback: ((CVPixelBuffer) -> Void)?
    private var bridge: IngestorBridge?
    
    public init() {}
    
    public func start(uri: String, onFrame: @escaping (CVPixelBuffer) -> Void) async {
        guard !isActive else { return }
        isActive = true
        self.onFrameCallback = onFrame
        
        await streamMonitor.setOnSynced { [weak self] frame in
            guard let self = self else { return }
            Task { await self.forwardFrame(frame) }
        }
        
        let newBridge = IngestorBridge(actor: self, monitor: streamMonitor)
        self.bridge = newBridge
        
        videoDecoder.delegate = newBridge
        audioDecoder.delegate = newBridge
        
        let (stream, continuation) = AsyncStream.makeStream(of: Data.self)
        self.streamContinuation = continuation
        
        self.processingTask = Task {
            for await data in stream {
                if Task.isCancelled || !self.isActive { break }
                autoreleasepool {
                    self.handleData(data)
                }
            }
        }
        
        await connect(uri: uri)
        startHeartbeat(uri: uri)
    }
    
    public func stop() {
        isActive = false
        if let source = readSource {
            source.cancel()
            readSource = nil
        }
        if socketFD >= 0 {
            close(socketFD)
            socketFD = -1
        }
        heartbeatTask?.cancel()
        streamContinuation?.finish()
        processingTask?.cancel()
        
        demuxer.reset()
        videoDecoder.reset()
    }
    
    private func parseURI(_ uri: String) -> (Bool, String, UInt16)? {
        let isMulticast = uri.contains("@")
        var cleanURI = uri.replacingOccurrences(of: "udp://", with: "")
        cleanURI = cleanURI.replacingOccurrences(of: "@", with: "")
        
        guard let url = URL(string: "rtsp://" + cleanURI), let host = url.host, let port = url.port else {
            let parts = cleanURI.split(separator: ":")
            if parts.count == 2, let p = UInt16(parts[1]) {
                return (isMulticast, String(parts[0]), p)
            }
            return nil
        }
        return (isMulticast, host, UInt16(port))
    }
    
    private func connect(uri: String) async {
        guard let (isMulticast, host, port) = parseURI(uri) else {
            print("UDPIngestor: Invalid URI \(uri)")
            return
        }
        
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else {
            print("UDPIngestor: Failed to create socket")
            return
        }
        self.socketFD = fd
        
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &reuse, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY
        
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        
        guard bindResult >= 0 else {
            print("UDPIngestor: Failed to bind socket")
            close(fd)
            self.socketFD = -1
            return
        }
        
        if isMulticast {
            var mreq = ip_mreq()
            mreq.imr_multiaddr.s_addr = inet_addr(host)
            mreq.imr_interface.s_addr = INADDR_ANY
            
            let joinResult = setsockopt(fd, IPPROTO_IP, IP_ADD_MEMBERSHIP, &mreq, socklen_t(MemoryLayout<ip_mreq>.size))
            if joinResult < 0 {
                print("UDPIngestor: Failed to join multicast group \(host)")
            } else {
                print("UDPIngestor: Joined Multicast Group \(uri)")
            }
        } else {
            print("UDPIngestor: Listening on Unicast \(uri)")
        }
        
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        
        self.lastPacketTime = Date().timeIntervalSince1970
        
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: DispatchQueue.global(qos: .userInitiated))
        let continuation = self.streamContinuation
        
        source.setEventHandler {
            var buffer = [UInt8](repeating: 0, count: 65536)
            var keepReading = true
            while keepReading {
                autoreleasepool {
                    let bytesRead = recv(fd, &buffer, buffer.count, 0)
                    if bytesRead > 0 {
                        let data = Data(buffer.prefix(bytesRead))
                        continuation?.yield(data)
                    } else {
                        keepReading = false
                    }
                }
            }
        }
        source.resume()
        self.readSource = source
    }
    
    private func handleData(_ data: Data) {
        lastPacketTime = Date().timeIntervalSince1970
        let events = demuxer.process(data: data)
        for event in events {
            switch event {
            case .nalUnit(let nal, let pts):
                videoDecoder.decode(nalUnit: nal, pts: pts)
            case .audio(let audio, let pts):
                audioDecoder.decode(audioPayload: audio, pts: pts)
            case .discontinuity:
                videoDecoder.reset()
            }
        }
    }
    
    private func startHeartbeat(uri: String) {
        heartbeatTask = Task {
            while isActive {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                if Task.isCancelled { break }
                
                let now = Date().timeIntervalSince1970
                if now - self.lastPacketTime > 5.0 {
                    if self.socketFD >= 0 {
                        print("UDPIngestor: Heartbeat timeout on \(uri). Resetting connection...")
                        if let source = self.readSource {
                            source.cancel()
                            self.readSource = nil
                        }
                        close(self.socketFD)
                        self.socketFD = -1
                        await self.connect(uri: uri)
                    }
                }
            }
        }
    }
    
    fileprivate func forwardFrame(_ frame: CVPixelBuffer) {
        onFrameCallback?(frame)
    }
}

fileprivate class IngestorBridge: H264DecoderDelegate, AudioDecoderDelegate {
    weak var actor: UDPIngestor?
    let monitor: StreamMonitor
    
    init(actor: UDPIngestor, monitor: StreamMonitor) {
        self.actor = actor
        self.monitor = monitor
    }
    
    func decoder(_ decoder: H264Decoder, didDecode frame: CVPixelBuffer, pts: Int64) {
        Task {
            let video = VideoHealth(frame: frame)
            await monitor.report(pts: pts, video: video, audio: nil)
        }
    }
    
    func decoder(_ decoder: AudioDecoder, didDecodeHealth health: AudioHealth, pts: Int64) {
        Task {
            await monitor.report(pts: pts, video: nil, audio: health)
        }
    }
}
