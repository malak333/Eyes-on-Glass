# Eyes on Glass: Signal Flow Analysis

This document illustrates the highly detailed end-to-end signal flow of the Eyes on Glass Swift backend media pipeline. It traces the journey of a livestream from the moment it is ingested as a UDP multicast packet down to the point where AI analytics results are recorded into the database.

## System Architecture

The pipeline demonstrates a native zero-copy mechanism bypassing standard sub-processes (like `ffmpeg`) to leverage Apple Silicon heavily across Swift actors, AudioToolbox, and native Vision models.

### End-to-End Evaluation Sequence

```mermaid
sequenceDiagram
    autonumber
    
    actor Network as Multicast Source
    participant Ingest as UDPIngestor (Actor)
    participant Demux as TSDemuxer
    participant VDecoder as H264Decoder (VTDecompression)
    participant ADecoder as AudioDecoder
    participant Monitor as StreamMonitor (Actor)
    participant LSS as LiveStreamService (Actor)
    participant CV as VisionAnalyzer (Native)
    participant AI as OllamaClient (Async VLM)
    participant DB as SQLite DB (Fluent ORM)
    participant UI as ExtractionProgress (Actor)

    Note over Network, Ingest: High Frequency Packet Ingestion
    Network->>Ingest: Incoming UDP Datagrams
    
    Ingest->>Demux: .process(data)
    Note over Demux: Extract PIDs (Video: 0xE0-0xEF, Audio: 0xC0-0xDF)<br>Process PES Headers, identify NAL Units
    Demux-->>Ingest: emit [ .nalUnit, .audio, .discontinuity ]
    
    par Hardware Video Decoding
        Ingest->>VDecoder: decode(nalUnit, pts, dts)
        Note over VDecoder: Converts Annex B to AVCC Multi-slice Format<br>Assembles CMBlockBuffer / CMSampleBuffer
        VDecoder->>VDecoder: VTDecompressionSessionDecodeFrame
        VDecoder-->>Ingest: didDecode(CVPixelBuffer, pts) [Delegate]
    and Audio Health Integrity
        Ingest->>ADecoder: decode(audioPayload, pts)
        Note over ADecoder: Analyzes PCM/Raw Buffer for abnormalities<br>(Clipping, Mute Drops, dB Peaking)
        ADecoder-->>Ingest: didDecodeHealth(AudioHealth, pts) [Delegate]
    end

    Note over Ingest, Monitor: Concurrency synchronization boundary
    Ingest->>Monitor: report(pts, video: CVPixelBuffer, audio: AudioHealth)
    
    Note over Monitor: 1. Buffers decoupled A/V streams by PTS<br>2. Evaluates alignment within strict 250ms Sync Window<br>3. Prunes stale buffers (500ms timeout)<br>4. Throttles ingress down to 1 Frame-Per-Second
    Monitor->>Monitor: evaluateIntegrity(pts, video, audio)
    
    alt A/V Synchronized & 1 FPS Governance Passed
        Monitor-->>LSS: onSyncedCallback(CVPixelBuffer)
    end
    
    Note over LSS: Media Transformation & Optimization
    LSS->>LSS: Convert CVPixelBuffer -> CIImage<br>Render localized JPEG data
    LSS->>LSS: Write target context to '/thumbnails/live_{UUID}.jpg'
    
    Note over LSS, CV: Native Mathematical Visual Validation
    LSS->>CV: analyze(imagePath: thumbURL)
    Note over CV: Evaluates raw matrix data (Accelerate/vImage):<br>Laplacian Variance (Blur), Pixel Tearing,<br>Blockiness deviation, Black Screens
    CV-->>LSS: Structured Vision Results
    
    alt Deterministic Media Failure (CV triggered)
        Note over LSS, DB: Prevent AI execution bottleneck when stream is obviously corrupt
        LSS->>DB: VideoLog.save() [Issue: macroblocking | blur | etc.]
    else Media is clean (proceed to AI Tiering limit ~ every 5s)
        Note over LSS, AI: Scalable VLM Tiering Architecture
        LSS->>AI: analyzeFrame(imagePath, model: "moondream")
        AI-->>LSS: Prediction Result (isSlate: Bool, Confidence: Double)
        
        alt First-pass anomaly detected
            LSS->>DB: VideoLog.save() [Issue: slate, Engine: quick_ai]
        else Moondream cleared frame
            LSS->>AI: analyzeFrame(imagePath, model: "llava")
            AI-->>LSS: Secondary Assurance Result
            alt Second-pass anomaly detected
                LSS->>DB: VideoLog.save() [Issue: slate, Engine: heavy_ai]
            end
        end
    else No Issues Detected / Un-evaluated Base FPS
        Note over LSS, DB: Sub-throttle logging. Only DB commit if 60s elapsed
        LSS->>DB: VideoLog.save() [Issue: "ok"]
    end
    
    Note over LSS: Cleanup intermediate thumbnail file
    LSS->>LSS: FileManager.removeItem(at: thumbURL)
    
    Note over LSS, UI: Progress reporting
    LSS->>UI: set(status: "extracting", current: frameCount)
```

## Component Roles & Responsibilities

- **`UDPIngestor`**: Native actor wrapping lightweight `NWConnection` equivalents via BSD Sockets handling high-frequency datagram payloads continuously.
- **`TSDemuxer`**: Responsible for the byte-level parsing of MPEG-TS formatting, tracking structural continuity counters, preventing packet fragmentation errors, and extracting precise Annex-B blocks.
- **`H264Decoder`**: Low-level CoreMedia bridge routing synchronized IDR/Non-IDR frames into the isolated Apple Silicon hardware `VTDecompressionSession`.
- **`StreamMonitor`**: Time-governing actor mapping separate Video tracking items alongside decoupled Audio buffers to perform temporal validation over drifting streams.
- **`LiveStreamService`**: The macro orchestrator translating clean CVPixelBuffer hardware frames into HTTP boundary-compliant tests, logging metrics down to the database asynchronously.
- **`VisionAnalyzer`**: Natively optimized framework assessing spatial and standard-deviation differences instantly. 
- **`OllamaClient`**: A locally orchestrated abstraction layer executing fast inference against Vision Language Models dynamically based on the severity and confidence required.
