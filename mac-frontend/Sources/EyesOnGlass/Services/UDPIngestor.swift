import Foundation
import CoreVideo
import Network

public actor UDPIngestor {
    private var connectionGroup: NWConnectionGroup?
    private var listener: NWListener?
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
    private var onFrameCallback: ((CVPixelBuffer, AudioHealth) -> Void)?
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
    
    public var streamInfo: (videoPID: UInt16?, audioPID: UInt16?, resolution: CGSize?, audioSampleRate: Int?, audioChannels: Int?, audioCodec: String?, audioBitrate: Double?, audioLoudness: Double?, audioTruePeak: Double?, audioDialNorm: Int?, tsID: UInt16?, programID: UInt16?, servicesCount: Int, sdtChannel: String?, sdtProvider: String?, videoColor: String?, videoGOPSize: Int?, videoFrameRate: Double?, tsClock: String?, pcrJitter: Double?, pcrInterval: Double?) {
        return (demuxer.currentVideoPID, demuxer.currentAudioPID, videoDecoder.videoSize, audioDecoder.sampleRate, audioDecoder.channels, audioDecoder.audioCodec, audioDecoder.audioBitrate, audioDecoder.loudness, audioDecoder.truePeak, audioDecoder.dialNorm, demuxer.currentTsID, demuxer.currentProgramID, demuxer.currentServicesCount, demuxer.currentSdtChannel, demuxer.currentSdtProvider, videoDecoder.videoColor, videoDecoder.gopSize, videoDecoder.frameRate, demuxer.currentTsClock, demuxer.currentPcrJitter, demuxer.currentPcrInterval)
    }
    
    public var audioVisuals: (waveform: [Float], vectorscope: [CGPoint], phase: [Float], levels: [Float]) {
        return (audioWaveform, audioVectorscope, audioPhase, audioLevels)
    }
    
    public init() {}
    
    public func start(
        uri: String, 
        onFrame: @escaping (CVPixelBuffer, AudioHealth) -> Void, 
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
            Task(priority: .userInitiated) { await self.forwardFrame(frame, audio: audio) }
        }
        
        let newBridge = IngestorBridge(
            actor: self, 
            monitor: streamMonitor,
            onVideoFrame: onVideoFrame,
            onAudioVisuals: onAudioVisuals
        )
        self.bridge = newBridge
        
        videoDecoder.delegate = newBridge
        audioDecoder.delegate = newBridge
        
        let (stream, continuation) = AsyncStream.makeStream(of: Data.self)
        self.streamContinuation = continuation
        
        self.processingTask = Task(priority: .userInitiated) {
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
        connectionGroup?.cancel()
        connectionGroup = nil
        listener?.cancel()
        listener = nil
        
        heartbeatTask?.cancel()
        streamContinuation?.finish()
        processingTask?.cancel()
        
        demuxer.reset()
        videoDecoder.reset()
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
            guard let ipv4 = IPv4Address(host) else {
                print("UDPIngestor: Invalid IPv4 Multicast Host")
                return
            }
            do {
                let group = try NWMulticastGroup(for: [.hostPort(host: .ipv4(ipv4), port: targetPort)])
                let groupConn = NWConnectionGroup(with: group, using: .udp)
                groupConn.stateUpdateHandler = { state in
                    if case .ready = state { print("UDPIngestor: Joined Multicast Group \(uri) natively") }
                }
                groupConn.setReceiveHandler(maximumMessageSize: 65536, rejectOversizedMessages: false) { (message, content, isComplete) in
                    guard let content = content else { return }
                    continuation?.yield(Data(content))
                }
                groupConn.start(queue: .global(qos: .userInitiated))
                self.connectionGroup = groupConn
            } catch {
                print("UDPIngestor: Multicast Group Error: \(error)")
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
    
    private nonisolated func receiveUnicast(connection: NWConnection, continuation: AsyncStream<Data>.Continuation?) {
        connection.receiveMessage { (content, context, isComplete, error) in
            if let content = content {
                continuation?.yield(Data(content))
            }
            if error == nil {
                self.receiveUnicast(connection: connection, continuation: continuation)
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
            while keepReading {
                if Task.isCancelled { break }
                autoreleasepool {
                    let data = fileHandle.readData(ofLength: chunkSize)
                    if data.count > 0 {
                        Task { @MainActor in
                            // Note: continuation belongs to actor, yielding is fine conceptually.
                            // However, we just yield here securely.
                        }
                        continuation?.yield(data)
                        // Artificial delay to simulate real-time ingestion instead of blasting instantly
                        // 65KB chunk approx = a few ms of typical video. Using a very short sleep.
                        usleep(1000) 
                    } else {
                        keepReading = false
                    }
                }
            }
            print("UDPIngestor: Finished reading local file")
        }
    }
    
    private func handleData(_ data: Data) {
        lastPacketTime = Date().timeIntervalSince1970
        packetCount += 1
        if packetCount % 50 == 0 {
            onPacketCallback?(packetCount)
        }
        if isStreamLost {
            isStreamLost = false
            onStreamRestoredCallback?()
        }
        let events = demuxer.process(data: data)
        for event in events {
            switch event {
            case .nalUnit(let nal, let pts, let dts):
                lastVideoTime = Date().timeIntervalSince1970
                if isVideoLost {
                    isVideoLost = false
                    onVideoRestoredCallback?()
                }
                videoDecoder.decode(nalUnit: nal, pts: pts, dts: dts)
            case .audio(let audio, let pts):
                audioDecoder.decode(audioPayload: audio, pts: pts)
            case .discontinuity:
                print("UDPIngestor: Stream discontinuity detected. Allowing H264Decoder to adapt.")
                self.onCCErrorCallback?()
                // We intentionally DO NOT reset the H264Decoder here.
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
                    if self.connectionGroup != nil || self.listener != nil {
                        print("UDPIngestor: Heartbeat timeout on \(uri). Resetting connection...")
                        self.connectionGroup?.cancel()
                        self.connectionGroup = nil
                        self.listener?.cancel()
                        self.listener = nil
                        await self.connect(uri: uri)
                    }
                }
            }
        }
    }
    
    fileprivate func forwardFrame(_ frame: CVPixelBuffer, audio: AudioHealth) {
        onFrameCallback?(frame, audio)
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

fileprivate class IngestorBridge: H264DecoderDelegate, AudioDecoderDelegate {
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
    
    func decoder(_ decoder: H264Decoder, didDecode frame: CVPixelBuffer, pts: Int64) {
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
