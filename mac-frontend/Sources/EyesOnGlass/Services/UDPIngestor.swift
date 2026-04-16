import Foundation
import CoreVideo
import Network
import Darwin

public actor UDPIngestor {
    private var connectionGroup: NWConnectionGroup?
    private var listener: NWListener?
    private var isActive = false
    private var bsdSocketFD: Int32 = -1
    private var bsdSocketTask: Task<Void, Never>?
    
    // Pipeline components
    private let demuxer = TSDemuxer()
    private var videoDecoder: HardwareVideoDecoder? = nil
    private var currentVideoCodec: VideoCodec = .unknown
    private let audioDecoder = AudioDecoder()
    private let streamMonitor = StreamMonitor()
    
    // Timers
    private var lastPacketTime: TimeInterval = 0
    private var windowMaxIAT: Double = 0.0
    private var heartbeatTask: Task<Void, Never>?
    private var processingTask: Task<Void, Never>?
    private var streamContinuation: AsyncStream<(Data, Double)>.Continuation?
    
    // Callback for LiveStreamService
    private var onFrameCallback: ((CVPixelBuffer, AudioHealth, Double) -> Void)?
    private var onAudioVisualsCallback: (([Float], [CGPoint], [Float], [Float]) -> Void)?
    private var onPacketCallback: ((Int) -> Void)?
    private var bridge: IngestorBridge?
    private var packetCount: Int = 0
    private var onStreamLostCallback: (() -> Void)?
    private var onStreamRestoredCallback: (() -> Void)?
    private var isStreamLost = false
    private var onVideoLostCallback: (() -> Void)?
    private var onVideoRestoredCallback: (() -> Void)?
    private var onCCErrorCallback: (() -> Void)?
    private var isVideoLost = false
    private var lastVideoTime: TimeInterval = 0
    
    // UI Audio Visuals
    private var audioWaveform: [Float] = []
    private var audioVectorscope: [CGPoint] = []
    private var audioPhase: [Float] = []
    private var audioLevels: [Float] = []
    
    public var streamInfo: (videoPID: UInt16?, audioPID: UInt16?, videoCodec: String?, resolution: CGSize?, audioSampleRate: Int?, audioChannels: Int?, audioCodec: String?, audioBitrate: Double?, audioLoudness: Double?, audioTruePeak: Double?, audioDialNorm: Int?, tsID: UInt16?, programID: UInt16?, servicesCount: Int, sdtChannel: String?, sdtProvider: String?, videoColor: String?, videoGOPSize: Int?, videoFrameRate: Double?, tsClock: String?, pcrJitter: Double?, pcrInterval: Double?) {
        let vc = currentVideoCodec == .unknown ? nil : currentVideoCodec.rawValue.uppercased()
        return (demuxer.currentVideoPID, demuxer.currentAudioPID, vc, videoDecoder?.videoSize, audioDecoder.sampleRate, audioDecoder.channels, audioDecoder.audioCodec, audioDecoder.audioBitrate, audioDecoder.loudness, audioDecoder.truePeak, audioDecoder.dialNorm, demuxer.currentTsID, demuxer.currentProgramID, demuxer.currentServicesCount, demuxer.currentSdtChannel, demuxer.currentSdtProvider, videoDecoder?.videoColor, videoDecoder?.gopSize, videoDecoder?.frameRate, demuxer.currentTsClock, demuxer.currentPcrJitter, demuxer.currentPcrInterval)
    }
    
    public var audioVisuals: (waveform: [Float], vectorscope: [CGPoint], phase: [Float], levels: [Float]) {
        return (audioWaveform, audioVectorscope, audioPhase, audioLevels)
    }
    
    public init() {}
    
    public func start(
        uri: String, 
        onFrame: @escaping (CVPixelBuffer, AudioHealth, Double) -> Void, 
        onVideoFrame: @escaping (CVPixelBuffer) -> Void,
        onAudioVisuals: @escaping ([Float], [CGPoint], [Float], [Float]) -> Void,
        onPacket: @escaping (Int) -> Void,
        onCCError: @escaping () -> Void = {},
        onStreamLost: @escaping () -> Void = {},
        onStreamRestored: @escaping () -> Void = {},
        onVideoLost: @escaping () -> Void = {},
        onVideoRestored: @escaping () -> Void = {}
    ) async {
        guard !isActive else { return }
        isActive = true
        self.onFrameCallback = onFrame
        self.onAudioVisualsCallback = onAudioVisuals
        self.onPacketCallback = onPacket
        self.onStreamLostCallback = onStreamLost
        self.onStreamRestoredCallback = onStreamRestored
        self.onVideoLostCallback = onVideoLost
        self.onVideoRestoredCallback = onVideoRestored
        self.onCCErrorCallback = onCCError
        
        await streamMonitor.setOnSynced { [weak self] frame, audio in
            guard let self = self else { return }
            Task(priority: .userInitiated) {
                let maxIAT = await self.captureAndResetIAT()
                await self.forwardFrame(frame, audio: audio, networkIAT: maxIAT)
            }
        }
        
        let newBridge = IngestorBridge(
            actor: self, 
            monitor: streamMonitor,
            onVideoFrame: onVideoFrame,
            onAudioVisuals: onAudioVisuals
        )
        self.bridge = newBridge
        
        audioDecoder.delegate = newBridge
        
        let (stream, continuation) = AsyncStream.makeStream(of: (Data, Double).self)
        self.streamContinuation = continuation
        
        self.processingTask = Task.detached(priority: .userInitiated) {
            for await (data, pktIat) in stream {
                await self.handleData(data, packetIat: pktIat)
            }
        }
        
        await connect(uri: uri)
        startHeartbeat(uri: uri)
    }
    
    public func stop() {
        isActive = false
        connectionGroup?.cancel()
        connectionGroup = nil
        listener?.cancel()
        listener = nil
        
        if bsdSocketFD != -1 {
            Darwin.close(bsdSocketFD)
            bsdSocketFD = -1
        }
        bsdSocketTask?.cancel()
        bsdSocketTask = nil
        
        heartbeatTask?.cancel()
        streamContinuation?.finish()
        processingTask?.cancel()
        
        demuxer.reset()
        videoDecoder?.reset()
        Task { [weak self] in
            await self?.streamMonitor.reset()
        }
        currentVideoCodec = .unknown
        packetCount = 0
    }
    
    private func parseURI(_ uri: String) -> (Bool, String, UInt16)? {
        let hasAt = uri.contains("@")
        var cleanURI = uri.replacingOccurrences(of: "udp://", with: "")
        cleanURI = cleanURI.replacingOccurrences(of: "@", with: "")
        
        let isMulticastHost: (String) -> Bool = { host in
            let parts = host.split(separator: ".")
            if let first = Int(parts.first ?? ""), first >= 224 && first <= 239 {
                return true
            }
            return false
        }
        
        guard let url = URL(string: "rtsp://" + cleanURI), let host = url.host, let port = url.port else {
            let parts = cleanURI.split(separator: ":")
            if parts.count == 2, let p = UInt16(parts[1]) {
                let h = String(parts[0])
                return (hasAt || isMulticastHost(h), h, p)
            }
            return nil
        }
        return (hasAt || isMulticastHost(host), host, UInt16(port))
    }
    
    private func connect(uri: String) async {
        if uri.hasPrefix("file://") {
            await connectToFile(uri: uri)
            return
        }
        
        guard let (isMulticast, host, port) = parseURI(uri) else {
            print("UDPIngestor: Invalid URI \(uri)")
            return
        }
        
        self.lastPacketTime = Date().timeIntervalSince1970
        self.lastVideoTime = Date().timeIntervalSince1970
        let continuation = self.streamContinuation
        
        let targetPort = NWEndpoint.Port(rawValue: port) ?? NWEndpoint.Port(integerLiteral: 1234)
        
        if isMulticast {
            print("UDPIngestor: Joined Multicast Group \(uri) natively via BSD Socket")
            let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
            if fd >= 0 {
                self.bsdSocketFD = fd
                var reuse: Int32 = 1
                setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
                setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &reuse, socklen_t(MemoryLayout<Int32>.size))
                
                var rcvbuf: Int32 = 8 * 1024 * 1024 // 8MB buffer avoids packet drops at native level
                setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rcvbuf, socklen_t(MemoryLayout<Int32>.size))
                
                var addr = sockaddr_in()
                addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                addr.sin_family = sa_family_t(AF_INET)
                addr.sin_port = port.bigEndian
                addr.sin_addr.s_addr = INADDR_ANY.bigEndian
                
                let bindResult = withUnsafePointer(to: &addr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
                
                if bindResult >= 0 {
                    var mreq = ip_mreq()
                    inet_pton(AF_INET, host, &mreq.imr_multiaddr)
                    mreq.imr_interface.s_addr = INADDR_ANY.bigEndian
                    setsockopt(fd, IPPROTO_IP, IP_ADD_MEMBERSHIP, &mreq, socklen_t(MemoryLayout<ip_mreq>.size))
                    var timestampOn: Int32 = 1
                    setsockopt(fd, SOL_SOCKET, SO_TIMESTAMP, &timestampOn, socklen_t(MemoryLayout<Int32>.size))
                    
                    let flags = fcntl(fd, F_GETFL)
                    fcntl(fd, F_SETFL, flags | O_NONBLOCK)
                    
                    self.bsdSocketTask = Task.detached(priority: .userInitiated) {
                        let bufferSize = 65536
                        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
                        
                        let controlBufSize = 256
                        let controlBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: controlBufSize)
                        
                        defer { 
                            buffer.deallocate()
                            controlBuf.deallocate()
                        }
                        
                        var batchData = Data()
                        batchData.reserveCapacity(65536)
                        var lastRecvTime: Double = 0
                        var batchPeakIAT: Double = 0
                        
                        var iov = iovec(iov_base: buffer, iov_len: Int(bufferSize))
                        var msg = msghdr()
                        
                        while true {
                            if Task.isCancelled { break }
                            var readSomething = false
                            while true {
                                msg.msg_name = nil
                                msg.msg_namelen = 0
                                msg.msg_iov = withUnsafeMutablePointer(to: &iov) { $0 }
                                msg.msg_iovlen = 1
                                msg.msg_control = UnsafeMutableRawPointer(controlBuf)
                                msg.msg_controllen = socklen_t(controlBufSize)
                                msg.msg_flags = 0
                                
                                let bytesRead = recvmsg(fd, &msg, 0)
                                if bytesRead > 0 {
                                    var packetTime = CFAbsoluteTimeGetCurrent() // Fallback to scheduler time
                                    
                                    if let controlPtr = msg.msg_control, msg.msg_controllen >= 12 {
                                        var cmsgPtr = controlPtr.assumingMemoryBound(to: cmsghdr.self)
                                        var remainingLen = Int(msg.msg_controllen)
                                        
                                        while remainingLen >= 12 {
                                            let cmsgLen = Int(cmsgPtr.pointee.cmsg_len)
                                            if cmsgLen < 12 || cmsgLen > remainingLen { break }
                                            
                                            // Extract the physical microsecond hardware interrupt payload
                                            if cmsgPtr.pointee.cmsg_level == SOL_SOCKET && cmsgPtr.pointee.cmsg_type == SCM_TIMESTAMP {
                                                let dataPtr = UnsafeRawPointer(cmsgPtr).advanced(by: 12)
                                                let tv = dataPtr.assumingMemoryBound(to: timeval.self).pointee
                                                packetTime = Double(tv.tv_sec) + (Double(tv.tv_usec) / 1_000_000.0)
                                                break
                                            }
                                            
                                            let alignedLen = (cmsgLen + 3) & ~3
                                            remainingLen -= alignedLen
                                            cmsgPtr = UnsafeMutableRawPointer(cmsgPtr).advanced(by: alignedLen).assumingMemoryBound(to: cmsghdr.self)
                                        }
                                    }
                                    
                                    if lastRecvTime > 0 {
                                        let iat = (packetTime - lastRecvTime) * 1000.0
                                        if iat > batchPeakIAT { batchPeakIAT = iat }
                                    }
                                    lastRecvTime = packetTime
                                    
                                    batchData.append(buffer, count: bytesRead)
                                    readSomething = true
                                    if batchData.count >= 65536 { break }
                                } else {
                                    break
                                }
                            }
                            
                            if batchData.count > 0 {
                                continuation?.yield((batchData, batchPeakIAT))
                                batchData.removeAll(keepingCapacity: true)
                                batchPeakIAT = 0
                            }
                            
                            if !readSomething {
                                var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                                poll(&pfd, 1, 1000)
                            }
                        }
                    }
                } else {
                    print("UDPIngestor: BSD Bind failed")
                    Darwin.close(fd)
                    self.bsdSocketFD = -1
                }
            }
        } else {
            do {
                let listener = try NWListener(using: .udp, on: targetPort)
                listener.stateUpdateHandler = { state in
                    if case .ready = state { print("UDPIngestor: Listening on Unicast \(uri) natively") }
                }
                listener.newConnectionHandler = { [weak self] connection in
                    connection.start(queue: .global(qos: .userInitiated))
                    self?.receiveUnicast(connection: connection, continuation: continuation)
                }
                listener.start(queue: .global(qos: .userInitiated))
                self.listener = listener
            } catch {
                print("UDPIngestor: Listener Error: \(error)")
            }
        }
    }
    
    private nonisolated func receiveUnicast(connection: NWConnection, continuation: AsyncStream<(Data, Double)>.Continuation?, lastTime: Double = CFAbsoluteTimeGetCurrent(), peakIAT: Double = 0) {
        connection.receiveMessage { [weak connection] (content, context, isComplete, error) in
            guard let connection = connection else { return }
            let now = CFAbsoluteTimeGetCurrent()
            let iterIat = (lastTime == 0) ? 0.0 : (now - lastTime) * 1000.0
            var newPeak = peakIAT
            if iterIat > newPeak { newPeak = iterIat }

            if let content = content {
                continuation?.yield((Data(content), newPeak))
                newPeak = 0
            }
            if error == nil {
                self.receiveUnicast(connection: connection, continuation: continuation, lastTime: now, peakIAT: newPeak)
            }
        }
    }
    
    private func connectToFile(uri: String) async {
        guard let url = URL(string: uri) else { return }
        print("UDPIngestor: Reading local offline file \(uri)")
        
        self.lastPacketTime = Date().timeIntervalSince1970
        self.lastVideoTime = Date().timeIntervalSince1970
        let continuation = self.streamContinuation
        
        Task.detached(priority: .userInitiated) {
            guard let fileHandle = try? FileHandle(forReadingFrom: url) else {
                print("UDPIngestor: Failed to read file")
                return
            }
            defer { try? fileHandle.close() }
            
            let chunkSize = 65536
            var keepReading = true
            var lastReadTime: Double = 0
            
            while keepReading {
                if Task.isCancelled { break }
                autoreleasepool {
                    let data = fileHandle.readData(ofLength: chunkSize)
                    if data.count > 0 {
                        let now = CFAbsoluteTimeGetCurrent()
                        let loopIat = (lastReadTime == 0) ? 0.0 : (now - lastReadTime) * 1000.0
                        lastReadTime = now
                        
                        continuation?.yield((data, loopIat))
                        // To simulate UDP micro-stutter timing delays natively for offline testing:
                        usleep(1000)
                    } else {
                        keepReading = false
                    }
                }
            }
            print("UDPIngestor: Finished reading local file")
        }
    }
    
    private func handleData(_ data: Data, packetIat: Double) {
        if packetIat > windowMaxIAT {
            windowMaxIAT = packetIat
        }
        
        self.lastPacketTime = Date().timeIntervalSince1970
        let beforeCount = self.packetCount
        self.packetCount += data.count / 188
        if (beforeCount / 50) < (self.packetCount / 50) {
            onPacketCallback?(packetCount)
        }
        if isStreamLost {
            isStreamLost = false
            onStreamRestoredCallback?()
        }
        let events = demuxer.process(data: data)
        for event in events {
            switch event {
            case .videoFrame(let codec, let data, let pts, let dts):
                lastVideoTime = Date().timeIntervalSince1970
                if isVideoLost {
                    isVideoLost = false
                    onVideoRestoredCallback?()
                }
                if codec != .unknown && codec != currentVideoCodec {
                    currentVideoCodec = codec
                    if codec == .h264 {
                        videoDecoder = H264Decoder()
                    } else if codec == .mpeg2 {
                        videoDecoder = MPEG2Decoder()
                    }
                    if let bridge = self.bridge {
                        videoDecoder?.decodedFrameCallback = { [weak bridge] frame, framePts in
                            bridge?.handleDecodedFrame(frame, pts: framePts)
                        }
                    }
                }
                videoDecoder?.decode(data: data, pts: pts, dts: dts)
            case .audio(let audio, let pts):
                audioDecoder.decode(audioPayload: audio, pts: pts)
            case .discontinuity:
                print("UDPIngestor: Stream discontinuity detected. Allowing HardwareVideoDecoder to adapt.")
                self.onCCErrorCallback?()
                // We intentionally DO NOT reset the videoDecoder here.
                // VTDecompressionSession can survive minor drops, and resetting requires an IDR frame 
                // which might not arrive for 30s, causing us to drop thousands of P-frames.
            }
        }
    }
    
    private func startHeartbeat(uri: String) {
        heartbeatTask = Task(priority: .utility) {
            while isActive {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { break }
                
                let now = Date().timeIntervalSince1970
                if now - self.lastVideoTime > 3.0 && !self.isStreamLost {
                    if !self.isVideoLost {
                        self.isVideoLost = true
                        self.onVideoLostCallback?()
                    }
                }
                
                if now - self.lastPacketTime > 5.0 {
                    if !self.isStreamLost {
                        self.isStreamLost = true
                        self.onStreamLostCallback?()
                    }
                    if self.connectionGroup != nil || self.listener != nil || self.bsdSocketFD != -1 {
                        print("UDPIngestor: Heartbeat timeout on \(uri). Resetting connection...")
                        self.connectionGroup?.cancel()
                        self.connectionGroup = nil
                        self.listener?.cancel()
                        self.listener = nil
                        if self.bsdSocketFD != -1 {
                            Darwin.close(self.bsdSocketFD)
                            self.bsdSocketFD = -1
                        }
                        self.bsdSocketTask?.cancel()
                        self.bsdSocketTask = nil
                        await self.connect(uri: uri)
                    }
                }
            }
        }
    }
    
    public func captureAndResetIAT() -> Double {
        let iat = windowMaxIAT
        windowMaxIAT = 0.0
        return iat
    }
    
    fileprivate func forwardFrame(_ frame: CVPixelBuffer, audio: AudioHealth, networkIAT: Double) {
        onFrameCallback?(frame, audio, networkIAT)
    }
    

    fileprivate func updateAudioVisuals(waveform: [Float], vectorscope: [CGPoint], phase: [Float], levels: [Float]) {
        self.audioWaveform = waveform
        self.audioVectorscope = vectorscope
        self.audioPhase = phase
        self.audioLevels = levels
        onAudioVisualsCallback?(waveform, vectorscope, phase, levels)
    }
    
    public func setMuted(_ muted: Bool) {
        audioDecoder.isMuted = muted
    }
}

fileprivate class IngestorBridge: AudioDecoderDelegate {
    weak var actor: UDPIngestor?
    let monitor: StreamMonitor
    let onVideoFrame: ((CVPixelBuffer) -> Void)?
    let onAudioVisuals: (([Float], [CGPoint], [Float], [Float]) -> Void)?
    
    init(actor: UDPIngestor, monitor: StreamMonitor, onVideoFrame: ((CVPixelBuffer) -> Void)?, onAudioVisuals: (([Float], [CGPoint], [Float], [Float]) -> Void)?) {
        self.actor = actor
        self.monitor = monitor
        self.onVideoFrame = onVideoFrame
        self.onAudioVisuals = onAudioVisuals
    }
    
    func handleDecodedFrame(_ frame: CVPixelBuffer, pts: Int64) {
        onVideoFrame?(frame)
        Task(priority: .userInitiated) {
            let video = VideoHealth(frame: frame)
            await monitor.report(pts: pts, video: video, audio: nil)
        }
    }
    
    func decoder(_ decoder: AudioDecoder, didDecodeHealth health: AudioHealth, pts: Int64) {
        Task(priority: .userInitiated) {
            await monitor.report(pts: pts, video: nil, audio: health)
        }
    }
    
    func decoder(_ decoder: AudioDecoder, didDecodeVisuals waveform: [Float], vectorscope: [CGPoint], phase: [Float], levels: [Float]) {
        onAudioVisuals?(waveform, vectorscope, phase, levels)
        Task(priority: .userInitiated) {
            await actor?.updateAudioVisuals(waveform: waveform, vectorscope: vectorscope, phase: phase, levels: levels)
        }
    }
}

#if DEBUG
extension UDPIngestor {
    public func _injectDataForTest(_ data: Data, packetIat: Double) {
        self.handleData(data, packetIat: packetIat)
    }
}
#endif
