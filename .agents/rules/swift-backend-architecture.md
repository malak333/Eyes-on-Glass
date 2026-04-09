# Swift Vapor Architecture & VideoToolbox Guidelines

When working on the native Apple Silicon media pipeline in the `swift-backend`, agents MUST adhere strictly to the following architectural patterns to prevent regressions in the production codebase.

## 1. VideoToolbox & Vapor Task Delegation
**CRITICAL:** Vapor operates on non-blocking NIO task threads. These threads do NOT instantiate standard `CFRunLoop` contexts. 
- You MUST NEVER use `._EnableAsynchronousDecompression` when calling `VTDecompressionSessionDecodeFrame` within the `H264Decoder` or any other VideoToolbox subsystem.
- Using asynchronous flags will result in the hardware decoder successfully decoding the frame but silently failing to invoke the `VTDecompressionOutputCallback` because there is no run loop to dispatch it back to.
- Always use `flags: []` (synchronous decoding) to block explicitly for nanoseconds in the Vapor thread so that the inline callback executes properly.

## 2. MPEG-TS Demuxing Constants
When maintaining the `TSDemuxer` or modifying how streams are identified and extracted from multiplexed TS files/streams:
- Standard MPEG audio utilizes stream identifiers between `0xC0` and `0xDF`.
- Production equipment and standard AC-3, E-AC-3, and LPCM commonly utilize Private Stream 1, identified specifically as `0xBD`.
- **CRITICAL:** When verifying if a PID is carrying an audio stream, you MUST include `0xBD` in your logic. Failing to do so will result in `StreamMonitor` failing to detect audio tracks, which subsequently triggers an intentional sequence stall due to A/V synchronization timeouts relying on both vectors.

## 3. Local Multicast Testing
macOS strictly restricts UDP multicast looping through standard interfaces.
- Always test local UDP ingestions using loopback unicast instead (e.g., `udp://127.0.0.1:4001`) with your FFmpeg tests.
- Do not attempt to force `UDPIngestor` IP detection mapping on `127.0.0.1` expecting standard multicast groups.

## 4. StreamMonitor Rate Limiting
To prevent memory exhaustion and 100% GPU spikes, the `StreamMonitor` must act as an explicit governor that aggressively culls frames before they reach the `LiveStreamService`.
- **CRITICAL:** `onSyncedCallback` MUST be strictly gated by a 1-FPS (90,000 PTS tick) threshold constraint.
- Never place callback triggers freely outside a time delta check. Unbounded triggering will flood the NIO Task pool with dozens of concurrent frames per second, crashing the host via linear memory leak and locking the GPU at 100%.
