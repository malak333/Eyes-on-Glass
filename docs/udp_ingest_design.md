# Eyes-on-Glass: Native UDP Video Ingestion Design (2026 "Pro" Way)

## 1. Understanding Summary
*   **What is being built:** A zero-copy, native Swift ingestion pipeline using `Network.framework` to listen for UDP packet streams and manually extract and decode video frames.
*   **Why it exists:** To completely eliminate the `ffmpeg` subprocess fallback, bypass unnecessary disk I/O, reduce latency, and tap directly into Apple Silicon hardware acceleration for decoding. 
*   **Who it is for:** The headless Vapor Swift backend processing live continuous video streams. 
*   **Key constraints:** The incoming stream will exclusively be MPEG-TS over UDP carrying H.264/H.265 bitstreams. The output of the decoder will be aggressively sub-sampled down to **1 frame per second**.
*   **Explicit non-goals:** We will **not** be displaying visual UI elements on the host running the server (no `AVSampleBufferDisplayLayer`). We are **not** supporting raw RTP transport (MPEG-TS only).

## 2. Explicit Assumptions
*   **Performance & Scale:** We assume the decoding hardware can handle peeling apart the MPEG-TS stream and discarding unused frames without exceeding CPU limits, as `NWConnection` and `VideoToolbox` are highly optimized on the Mac.
*   **Reliability & Resilience:** UDP implies packet loss. We assume the demuxer and decoder logic will gracefully handle corrupted packets, flushing buffers and searching for the next Sequence Parameter Set (SPS/PPS keyframes) rather than crashing the Vapor service.
*   **Architecture & Maintenance:** The new native pipeline resides inside `LiveStreamService.swift` via a dedicated Actor, cleanly hooking into the existing `VisionAnalyzer` loop with `CVPixelBuffer` inputs rather than JPEG file paths.

## 3. Decision Log
1.  **Format:** MPEG-TS carrying H.264/H.265 exclusively. (Chosen for scope control, bypassing pure RTP).
2.  **Display:** Headless only. Decoded frames are exclusively passed as `CVPixelBuffer` directly to `VisionAnalyzer`. (Chosen to preserve UI/Server boundaries).
3.  **Performance:** Drop all parsed frames silently except for 1 Frame-Per-Second to prevent system memory overload while retaining parity with the old `ffmpeg` output rate.
4.  **Architecture Strategy:** Single Native Swift Actor Pipeline. (Chosen over Combine/C++ interop for robust native performance and state safety without external dependencies).

## 4. Final Design

### Architecture & Components
The system will introduce three primary internal components to handle ingest decoupled from standard Vapor logic:

1.  **`UDPIngestor` (Actor):** Wraps `NWConnection` to set up UDP routing and initiates an async `.receiveMessage` loop. Pushes raw `Data` to the demuxer.
2.  **`TSDemuxer` (Class/Struct):** Executes byte-level parsing. Scans for `0x47` sync bytes, parses PIDs to locate video, processes PES headers, and extracts raw Annex B H.264/H.265 NAL Units.
3.  **`H264Decoder`:** Wraps `VTDecompressionSession`. It converts Annex B formats into `CMBlockBuffer` and `CMSampleBuffer`, decoding them. Inside the `VTDecompressionOutputCallback`, it enforces the 1 fps speed limit and yields the raw `CVPixelBuffer` back to `LiveStreamService`.

### Error Handling & Resilience
1.  **Network Stalls:** `UDPIngestor` manages `NWConnection` state. Reconnections use an exponential backoff loop. A background timer task forcefully kills and resets the connection if no packets arrive within a 5-second window.
2.  **Corrupted Packets:** `TSDemuxer` monitors the TS Continuity Counter. Discontinuities instantly flush the assembly buffer. `H264Decoder` is instructed to drop all data until the next IDR (I-Frame) is detected to prevent decoding grey/blocky corrupted artifacts into `VisionAnalyzer`.
3.  **Decoder Failures:** Malformed packets triggering `VideoToolbox` errors (`kVTVideoDecoderBadDataErr`) are caught, yielding a secure session reset.

### Testing Strategy
1.  **Isolated Byte-Level Unit Tests:** Static, known-good binary `MPEG-TS` fragments will be fed into the `TSDemuxer` in `XCTest` to rigidly verify byte math, `0x47` parsing, and NAL extraction without network variables.
2.  **Local Loopback Integration:** A script transmitting an MP4 over localhost UDP will be used to assert the resulting `CVPixelBuffer` frames arrive exactly at the 1 fps cadence via the native `LiveStreamService`.
3.  **Memory Profiling:** Zero-copy verification via Xcode Instruments to ensure `CVPixelBuffer` handles are immediately released post-analysis and the resident set size (RSS) remains steady.
