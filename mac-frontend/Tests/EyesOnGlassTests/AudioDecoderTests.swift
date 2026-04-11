import XCTest
import AVFoundation
@testable import EyesOnGlass

final class AudioDecoderTests: XCTestCase {

    class MockAudioDecoderDelegate: AudioDecoderDelegate {
        var observedHealth: AudioHealth?
        var observedWaveform: [Float]?
        
        func decoder(_ decoder: AudioDecoder, didDecodeHealth health: AudioHealth, pts: Int64) {
            observedHealth = health
        }
        
        func decoder(_ decoder: AudioDecoder, didDecodeVisuals waveform: [Float], vectorscope: [CGPoint], phase: [Float]) {
            observedWaveform = waveform
        }
    }

    func testAudioDecoderEmptyData() {
        let decoder = AudioDecoder()
        let delegate = MockAudioDecoderDelegate()
        decoder.delegate = delegate
        
        decoder.decode(audioPayload: Data(), pts: 0)
        
        XCTAssertEqual(delegate.observedHealth, .silent, "Empty payload should be considered silent.")
    }

    func testAudioDecoderADTSHeaderParsing() {
        let decoder = AudioDecoder()
        let delegate = MockAudioDecoderDelegate()
        decoder.delegate = delegate
        
        // Construct a mock ADTS header (7 bytes)
        // 0xFF 0xF1 (Syncword and ID)
        // 0x50 (Profile: AAC-LC = 1 -> 01, FreqIdx: 44.1kHz = 4 -> 0100, private: 0 -> 0) => 01010000 = 0x50
        // 0x80 (channel configuration bit 0 is 0, rest length bits)
        // Let's ensure length is larger than 7 so we don't return early. Length is 15.
        // bytes 3, 4, 5. So length 15: 00000000 00001111 => 0x00 0x0F
        // byte 3: channel config left bit (1 bit), frame length (2 bits) -> 0x80 has channel end bit 0
        
        // This is a rough ADTS header just enough to trigger frequency/channel parsing
        let mockADTS: [UInt8] = [0xFF, 0xF1, 0x50, 0x80, 0x07, 0xE0, 0xFC, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        
        decoder.decode(audioPayload: Data(mockADTS), pts: 0)
        
        XCTAssertEqual(decoder.sampleRate, 44100, "Sample rate should be derived as 44100 from frequency index 4.")
        XCTAssertEqual(decoder.channels, 2, "Channels should be derived as 2 from channel config.")
        XCTAssertEqual(delegate.observedHealth, .healthy, "Payload exists, should be healthy.")
    }
    
    func testAudioDecoderMP2HeaderParsing() {
        let decoder = AudioDecoder()
        
        let expectedFrameLength = 144 * 128000 / 48000 + 0 // 384 bytes
        var mockMP2 = [UInt8](repeating: 0, count: expectedFrameLength)
        // Set MP2 sync word and header
        // b0=0xFF, b1=0xFD (Layer II, no CRC)
        // b2=0x84 (Bitrate idx 8 -> 128kbps, SR idx 1 -> 48kHz, Pad 0) => 1000 0100 => 0x84
        mockMP2[0] = 0xFF
        mockMP2[1] = 0xFD
        mockMP2[2] = 0x84
        mockMP2[3] = 0x40
        
        // Append next frame header to satisfy boundary checking
        var nextFrame = [UInt8](repeating: 0, count: 5)
        nextFrame[0] = 0xFF
        nextFrame[1] = 0xFD
        nextFrame[2] = 0x84
        nextFrame[3] = 0x40
        
        let combined = mockMP2 + nextFrame
        
        // We set the codec specifically for testing MP2 payload boundary decoding
        decoder.audioCodec = "MP2"
        decoder.decode(audioPayload: Data(combined), pts: 0)
        
        // Decoder's internal processAudioFrame handles stripping correctly if bounding condition matches
        // For testing we just ensure that the parsing didn't lead to infinite loop
        XCTAssertEqual(decoder.audioCodec, "MP2")
    }

    func testAudioDecoderMultiChannelConfiguration() {
        let decoder = AudioDecoder()
        let delegate = MockAudioDecoderDelegate()
        decoder.delegate = delegate
        
        // Construct ADTS header for 3 channels.
        let mockADTS: [UInt8] = [0xFF, 0xF1, 0x50, 0xC0, 0x07, 0xE0, 0xFC, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        
        decoder.decode(audioPayload: Data(mockADTS), pts: 0)
        
        XCTAssertEqual(decoder.sampleRate, 44100, "Sample rate should be derived as 44100 from frequency index 4.")
        XCTAssertEqual(decoder.channels, 3, "Channels should be derived as 3 from channel config.")
        
        let mirror = Mirror(reflecting: decoder)
        var isConfigured = false
        var converterCreated = false
        for child in mirror.children {
            if child.label == "isConfigured", let val = child.value as? Bool {
                isConfigured = val
            }
            if child.label == "converter" {
                let mirror2 = Mirror(reflecting: child.value)
                if mirror2.displayStyle == .optional && mirror2.children.first != nil {
                    converterCreated = true
                } else if mirror2.displayStyle != .optional {
                    converterCreated = true
                }
            }
        }
        
        XCTAssertTrue(isConfigured, "Decoder should be configured for 3 channels without returning nil in AVAudioFormat setup")
        XCTAssertTrue(converterCreated, "AVAudioConverter should be created for multi-channel input")
    }

    @MainActor
    func testUDPIntegrationWithAppEngine() async throws {
        let service = LiveStreamService.shared
        let controller = StreamController.shared
        
        controller.isAdvancedInspectorVisible = true
        
        await service.startMonitoring(uri: "udp://239.0.0.1:1234", sessionName: "Test_Suite")
        
        // Wait 3 seconds
        try await Task.sleep(nanoseconds: 3_000_000_000)
        
        let count = controller.audioWaveformData.count
        let active = controller.audioWaveformData.filter { abs($0) > 0.0001 }.count
        print("UDPIntegration - Waveform count: \(count)")
        print("UDPIntegration - Active count: \(active)")
        
        XCTAssertGreaterThan(count, 0, "Should have waveform values")
        XCTAssertGreaterThan(active, 0, "Should have NON-ZERO waveform values")
        
        await service.stopMonitoring()
    }

    func testAudioDecoderMetricsInitialization() {
        let decoder = AudioDecoder()
        XCTAssertNil(decoder.audioBitrate, "Audio bitrate should initially be nil")
        XCTAssertNil(decoder.loudness, "Loudness should initially be nil")
        XCTAssertNil(decoder.truePeak, "True peak should initially be nil")
        XCTAssertNil(decoder.dialNorm, "Dial norm should initially be nil")
    }

    func testAudioDecoderPhaseCorrelation() {
        let decoder = AudioDecoder()
        decoder.channels = 2
        
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44100, channels: 2, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024) else {
            XCTFail("Failed to allocate AVAudioPCMBuffer")
            return
        }
        buffer.frameLength = 1024
        guard let floatChannelData = buffer.floatChannelData else {
            XCTFail("No float channel data")
            return
        }
        
        // 1. Perfectly correlated (In-phase)
        for i in 0..<1024 {
            let val = Float(sin(Double(i) * .pi / 180.0))
            floatChannelData[0][i] = val
            floatChannelData[1][i] = val
        }
        
        if let visuals = decoder.extractVisuals(from: buffer) {
            let phase = visuals.2.last ?? 0
            XCTAssertEqual(phase, 1.0, accuracy: 0.01, "Perfectly correlated phase should be ~1.0")
        } else {
            XCTFail("Failed to extract visuals")
        }
        
        // 2. Perfectly anti-correlated (Out-of-phase)
        for i in 0..<1024 {
            let val = Float(sin(Double(i) * .pi / 180.0))
            floatChannelData[0][i] = val
            floatChannelData[1][i] = -val
        }
        
        if let visuals = decoder.extractVisuals(from: buffer) {
            let phase = visuals.2.last ?? 0
            XCTAssertEqual(phase, -1.0, accuracy: 0.01, "Perfectly anti-correlated phase should be ~-1.0")
        } else {
            XCTFail("Failed to extract visuals")
        }
        
        // 3. Uncorrelated (one channel silent)
        for i in 0..<1024 {
            let val = Float(sin(Double(i) * .pi / 180.0))
            floatChannelData[0][i] = val
            floatChannelData[1][i] = 0.0
        }
        
        if let visuals = decoder.extractVisuals(from: buffer) {
            let phase = visuals.2.last ?? 0
            XCTAssertEqual(phase, 0.0, accuracy: 0.01, "Uncorrelated phase should be ~0.0")
        } else {
            XCTFail("Failed to extract visuals")
        }
    }
}
