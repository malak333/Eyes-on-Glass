import XCTest
import Network
import CoreVideo
@testable import EyesOnGlass

final class LiveMulticastLoadTest: XCTestCase {
    
    func testNetworkFrameworkThroughput() async throws {
        let path = "/Users/michaelnobile/Video Assets/kabc-20MB.ts"
        guard FileManager.default.fileExists(atPath: path) else {
            XCTFail("Asset not found: \(path)")
            return
        }
        
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        // Cap the test to 50MB to avoid excessively long test times while stabilizing TCP/UDP windows
        let totalSize = min(data.count, 50_000_000) 
        let chunkSize = 1316 // Standard 7 TS packet UDP datagram size
        var offset = 0
        
        let ingestor = UDPIngestor()
        actor Metrics {
            var framesDecoded = 0
            var packetsReceived = 0
            func addFrame() { framesDecoded += 1 }
            func updatePackets(_ count: Int) { packetsReceived = count }
        }
        let metrics = Metrics()
        
        await ingestor.start(
            uri: "udp://127.0.0.1:45678",
            onFrame: { _, _, _ in },
            onVideoFrame: { _ in Task { await metrics.addFrame() } },
            onAudioVisuals: { _, _, _, _ in },
            onPacket: { count in Task { await metrics.updatePackets(count) } }
        )
        
        // Wait for listener to bind
        try await Task.sleep(nanoseconds: 1_000_000_000)
        
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: 45678)
        let connection = NWConnection(to: endpoint, using: .udp)
        connection.start(queue: .global(qos: .userInitiated))
        
        // Wait for connection
        try await Task.sleep(nanoseconds: 500_000_000)
        
        print("====== UDP LIVE SYNC STARTING ======")
        let startTime = CFAbsoluteTimeGetCurrent()
        
        
        let blastQueue = DispatchQueue(label: "com.eyesonGlass.udpBlast", qos: .userInteractive)
        await withCheckedContinuation { continuation in
            blastQueue.async {
                let concurrencyLimit = DispatchSemaphore(value: 80)
                while offset < totalSize {
                    concurrencyLimit.wait()
                    let size = min(chunkSize, totalSize - offset)
                    let chunk = data.subdata(in: offset..<offset+size)
                    
                    connection.send(content: chunk, completion: .contentProcessed({ _ in
                        concurrencyLimit.signal()
                    }))
                    offset += size
                    usleep(15) // pace to approx 80 MB/sec to avoid kernel completely dropping the socket layer
                }
                continuation.resume()
            }
        }
        
        let blastEndTime = CFAbsoluteTimeGetCurrent()
        let elapsed = blastEndTime - startTime
        
        // Let the Native AVFoundation H264 decoder finish decoding its hardware queue
        try await Task.sleep(nanoseconds: 1_500_000_000)
        
        let mbSent = Double(totalSize) / 1_000_000.0
        let sendThroughput = mbSent / elapsed
        let framesOut = await metrics.framesDecoded
        let packetsIn = await metrics.packetsReceived
        
        let logOut = """
        \\n====================================
        🚀 ZERO-COPY NETWORK INGESTION BENCHMARK
        ====================================
        Pushed Asset Size: \(mbSent) MB
        Total Sent Packets (1316b): \(totalSize / chunkSize)
        Receiver Registered Packets: \(packetsIn)
        Total Frames Hardware Decoded: \(framesOut)
        
        Raw Send Time: \(String(format: "%.3f", elapsed)) seconds
        Real-Time UDP Loopback Throughput: \(String(format: "%.2f", sendThroughput)) MB/sec
        
        Theoretical Safe Capacity limit (2.5 MB/sec per 20Mbps stream):
        Single Thread Estimate: \(Int(sendThroughput / 2.5)) simultaneous streams
        ====================================\\n
        """
        
        print(logOut)
        fflush(stdout)
        try? logOut.write(to: URL(fileURLWithPath: "/tmp/live_multicast_result.txt"), atomically: true, encoding: .utf8)
        
        // Cleanup
        connection.cancel()
        await ingestor.stop()
        
        // Verification assert
        XCTAssertGreaterThan(framesOut, 5, "Should have hardware-decoded queue of frames!")
    }
}
