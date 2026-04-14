import Foundation
import XCTest
@testable import EyesOnGlass

final class FastIntegrationTests: XCTestCase {
    
    class MockBridge: AudioDecoderDelegate {
        var visualCount: Int = 0
        var activeWaveformCount: Int = 0
        
        func decoder(_ decoder: AudioDecoder, didDecodeHealth health: AudioHealth, pts: Int64) { }
        
        func decoder(_ decoder: AudioDecoder, didDecodeVisuals waveform: [Float], vectorscope: [CGPoint], phase: [Float], levels: [Float]) {
            visualCount += 1
            let active = waveform.filter({ abs($0) > 0.0001 }).count
            if active > 0 {
                activeWaveformCount += 1
            }
        }
    }
    
    func testFileParsing() {
        let path = "/Users/michaelnobile/Video Assets/kabc-20MB.ts"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            XCTFail("Could not read file")
            return
        }
        
        let demuxer = TSDemuxer()
        let audioDecoder = AudioDecoder()
        let mockBridge = MockBridge()
        
        audioDecoder.delegate = mockBridge
        
        var payloadCount = 0
        print("Starting parsing of \(data.count) bytes...")
        
        let packetSize = 188
        var offset = 0
        let testSize = 50_000_000 // Test 50MB
        let startTime = CFAbsoluteTimeGetCurrent()
        
        while offset + packetSize <= data.count {
            let chunk = data.subdata(in: offset..<offset+packetSize)
            let events = demuxer.process(data: chunk)
            for event in events {
                if case let .audio(payload, pts) = event {
                    payloadCount += 1
                    audioDecoder.decode(audioPayload: payload, pts: pts)
                }
            }
            offset += packetSize
            
            if offset >= testSize { break }
        }
        
        let endTime = CFAbsoluteTimeGetCurrent()
        let elapsed = endTime - startTime
        let mbProcessed = Double(offset) / 1_000_000.0
        let mbPerSecond = mbProcessed / elapsed
        let streams20Mbps = mbPerSecond / 2.5 // 20 Mbps = 2.5 MB/s
        
        let logOut = """
        ====== BENCHMARK RESULTS ======
        Processed \(mbProcessed) MB in \(String(format: "%.3f", elapsed)) seconds.
        Throughput: \(String(format: "%.2f", mbPerSecond)) MB/sec.
        Estimated simultaneous 20Mbps streams: \(Int(streams20Mbps))
        ====== AUDIO PAYLOADS: \(payloadCount) ======
        Visuals received: \(mockBridge.visualCount)
        Active waveforms: \(mockBridge.activeWaveformCount)
        =====================================
        """
        print(logOut)
        

        XCTAssertTrue(mockBridge.visualCount > 0, "No visuals received!")
        
        XCTAssertGreaterThan(payloadCount, 0, "No payload parsed from TS")
        
        XCTAssertGreaterThan(mockBridge.visualCount, 0, "Should have received audio visuals")
        XCTAssertGreaterThan(mockBridge.activeWaveformCount, 0, "Should have ACTIVE audio arrays")
    }
}
