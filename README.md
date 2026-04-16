# Eyes on Glass

**Eyes on Glass** is an AI-powered concept application that monitors video streams (e.g., `.ts`, `.mp4`) for visual/audio anomalies like lip-sync issues, macroblocking, pure black screens, slates, top artifacts, and audio corruptions (like dropouts, severe buzzing, or sporadic clicking). Instead of monitoring the stream at 60 FPS, this application natively extracts an optimized subset of frames (1 FPS) for analysis, drastically improving performance while retaining fidelity. 

The entire system is a **standalone, native macOS desktop application** specifically built for Apple Silicon (M-series with 32GB RAM).

---

## 🏗 Architecture

The platform architecture is unified into a single SwiftUI macOS Application Package (`mac-frontend/`):

1. **Frontend (SwiftUI + SwiftUI Glassmorphism)**: 
   - A highly reactive macOS application UI targeting macOS 14+ (Sonoma and newer).
   - Designed with an ultra-premium aesthetic utilizing raw `.ultraThinMaterial` backgrounds and modern, monospaced typography.
   - Monitors timeline intelligence, live stream health status, and dynamic internal hardware consumption (CPU, Memory, GPU) across adjustable timeframes.
   - Incorporates TabView-based navigation featuring a real-time **Dashboard** and a persistent **History** tab utilizing native macOS `Table` components.
   - Dynamically subscribes to real-time `SwiftData` context updates via `@Query`, seamlessly pulling background hardware extraction telemetry.

2. **Ingestion Engine & Hardware Extraction**:
   - The former Vapor engine is now completely decoupled. The platform receives A/V payloads completely autonomously natively bypassing network abstraction bottlenecks.
   - Delegates local processing to **AVFoundation/AVAssetReader**, carving out frames directly into memory, dramatically outscaling sub-process FFmpeg extraction speeds.
   - **Live Multicast Integration (`LiveStreamService`)**: A dedicated concurrent actor natively ingests infinite UDP streams utilizing highly optimized **POSIX BSD Sockets natively via the `Darwin` framework**. This shift completely decouples multicast ingestion from Apple's higher-level `Network.framework` (`NWConnectionGroup`), allowing for explicit manipulation of the underlying kernel bounds. By scaling the `SO_RCVBUF` OS socket limit to **8MB**, the architecture natively shields against all OS-layer packet dropping induced by 20Mbps burst micro-stutters—permanently solving stream discontinuity ("CC Errors"). Furthermore, processing utilizes an ultra-rapid non-blocking loop leveraging `recv` and `poll` to batch incoming sequences into 64KB `Data` chunks seamlessly, driving internal cross-actor propagation backpressure to near-zero levels. Processing leverages a multi-track parsing engine (`TSDemuxer`) powered by a **Zero-Allocation Cursor** to parse packets natively without invoking dynamic memory re-allocations. Real-time ingestion occurs transparently within strict `.userInitiated` Quality of Service bounds—legally confining video parsing and network frame propagation strictly to Apple Silicon Performance (P) Cores while seamlessly routing telemetry dumps to Efficiency (E) Cores (`.utility`) to prevent kernel-level UDP multicast buffer exhaustion.
   - **Native Dual-Codec Hardware Decoding Framework**: The multitrack routing engine aggressively manages underlying Apple Silicon acceleration boundaries simultaneously. `TSDemuxer` autonomously scans and extracts payload definitions natively using the sequence **Program Map Table (PMT)** to map and lock to active video sub-channels natively (supporting both modern HEVC/H.264 boundaries directly mapped over standard `0x1B` parameter-sets alongside legacy analog MPEG-2 encoding schemas via `0x02` allocations). `UDPIngestor` observes underlying protocol bindings and seamlessly hot-swaps `HardwareVideoDecoder` instantiations within milliseconds mid-broadcast without stalling the visual pipeline. The `H264Decoder` strictly manages mapping formats dynamically—aggressively validating incoming Sequence (SPS) and Picture (PPS) Parameter Sets natively bypassing missing IDR locks. The `MPEG2Decoder` explicitly validates deterministic container state bindings (`currentFrameHasSlices`) instead of relying on arbitrary byte-size payload truncation to strip padding and isolated sequence headers gracefully, rendering pipeline failures (like standard `VTDecompressionSessionDecodeFrame` `-12909` exceptions) mathematically impossible.
   - **Zero-Copy Visual Rendering (`SampleBufferVideoView`)**: Extracted video bytes bypass SwiftUI limits utterly. Extracted `CVPixelBuffer`s from the `LiveStreamService` are statically broadcasted across an invisible local `Combine` subject straight to the GPU framework (`AVSampleBufferDisplayLayer`) without engaging `@State` or manual CPU context mapping like `CIImage`. This allows unbounded frames-per-second propagation seamlessly without inducing arbitrary layout stalls.
   - **Real-Time Audio Telemetry**: The audio stream is actively monitored via continuous payload analysis (supporting ADTS AAC, MP2, MP3, and AC-3 codecs). AC-3 payload framing is rigorously mapped using static **ATSC A/52 standard guidelines** to prevent native buffer drops. `AVAudioConverter` transforms incoming audio packets into `Float32` linear PCM. This data is piped directly to Apple's **Accelerate (vDSP)** hardware to execute zero-latency Fast Fourier Transforms (FFTs), true-peak analysis, and hardware stereo-to-mono mixing via `vDSP_vasm`. These vectorized arrays are bound straight into SwiftUI canvases to render ultra-smooth Waveforms, Vectorscopes, Audio Phase measurements, and Channel Peaks at 30 fps without stalling Swift's main thread loop.

3. **Analysis Engine (Hybrid VLM Pipeline & Gemma 4 E4B)**:
   - To optimize extreme performance, the application implements a **Hybrid VLM Pipeline** pairing classical computer vision heuristics natively with State-of-the-Art Generative AI.
   - **OpenCV Junior Pre-Filter**: Streams frames concurrently via standard Swift `Actor` execution loops. Fast heuristics (like Laplacian variance and blockiness calculations) actively monitor stream health without invoking the LLM. This filter executes natively against Apple's unified memory (zero-copy via `vImage`), completely bypassing SSD disk I/O unless an anomaly dictates a persistent flush.
   - **Zero-Gradient Density Graphic Gate**: To explicitly exclude false-positives caused by full-screen broadcast graphics (like commercial slates), the OpenCV pipeline computes mathematical pixel flatness natively. If a frame consists of over 15% zero-gradient regions (or if the scene is exceptionally dark), the pipeline suppresses primitive macroblocking heuristics to bypass aggressive codec artifacts.
   - **Hardware-Accelerated Ring Buffer**: A persistent 30-frame visual trail is dynamically maintained in memory. To minimize overhead and dramatically scale throughput, raw `CVPixelBuffer` frames are synchronously encoded into HEIC (High-Efficiency Image Container) formats utilizing Apple's M4/M5 hardware Media Engine. When an anomaly is identified, these highly-compressed HEIC bytes are securely flushed directly to disk without any secondary, redundant JPEG software trans-coding (completely eliminating "Synchronous Dual Image Compression").
   - **Gemma 4 "Senior Engineer" Validation Arbitration**: When the VLM takes over the sequence evaluation natively, it strictly arbitrates all visual fidelity issues. The pipeline automatically strips primitive OpenCV spatial anomalies (e.g., OpenCV macroblocking false-positives), ensuring the LLM acts as the absolute single source-of-truth for visual payloads without polluting the database with duplicate transient telemetry.
   - **Stateless Zero-Shot Inference**: To completely eliminate ambient GPU and Core processing overhead, the VLM operates entirely on-demand. Background cache polling has been disabled. When OpenCV escalates a potential incident, the Native VLM instantly reconstructs its MLX context utilizing raw snapshot frames directly from the hardware HEIC ring buffer. This enforces a strict zero-shot architectural boundary, preventing any hallucinated context leakage between isolated broadcast corruptions.
   - **Consecutive Frame Arbitration**: For rapid anomalies like macroblocking, transient encoder artifacts often masquerade as stream errors (e.g., standard commercial flash-fades or transitions). To aggressively combat false-positives, the analysis engine introduces a **two-frame consecutive threshold**. A first VLM validation places the framework into an active "pending" state. It requires a contiguous second frame to also be mathematically confirmed offline or live (at an adjusted 5 FPS extraction sampling rate) before the `StreamController` logs the incident to the forensic database.
   - **Asynchronous & Detached AI Validation**: To protect the `LiveStreamService` frame-processing limits and guarantee that UI buttons (such as "Disconnect") remain instantaneously reactive during VLM spin-ups, the pipeline shifts raw Gemma inferences into entirely detached low-priority structures (`Task(priority: .utility)`). High value `HEIC` ring-buffer thumbnails are natively retained (`retainFileOnDisk`) dynamically until the background MLX pipeline safely reconciles mathematical anomalies. Once validated, results are merged safely to the main actor loop and the temporary local image assets are aggressively removed using immediate OS garbage-collection.
   - **Temporal Black Screen Arbitration**: Black screen detections now utilize a delayed 7-second hardware buffer. The VLM acts as a broadcast engineer, analyzing the pre-drop frame, the black period, and the restored video simultaneously to accurately distinguish between clean transitions (like commercial fades) and absolute technical failures. This drastically eliminates false-positive loss-of-signal alerts without compromising reaction speed.
4. **Telemetry Logging (`SwiftData` & Rate Limiting)**:
   - **Real-Time Context Synchronization**: To minimize pipeline latency upon incident creation, internal `SwiftData` buffer insertions are executed utilizing native thread-safe `@MainActor` closures. This guarantees instantaneous reactivity from SwiftUI layer `@Query` structures inside the application dashboard for completely real-time diagnostic logs. 
   - **Debounced Disk Writes & Backpressure Mitigation**: Rather than forcefully serializing massive data insertions via synchronous `try? context.save()` calls immediately over the `LiveStreamService` loop, the ingestion architecture detaches all SQLite logging events using `Task { @MainActor }`. SwiftData natively holds the rapid anomalies within the in-memory context (serving the UI instantly), while a dedicated lightweight `.onReceive` timer inside the dashboard explicitly debounces and throttles actual heavy SQLite disk `flushToDisk()` operations securely behind an asynchronous 5-second boundary, entirely preventing actor suspension cross-locks.
   - **Forensic Frame Metrics**: Enhanced diagnostic telemetry now tracks precise `IAT` (Inter-Arrival Time) natively at the raw `UDPIngestor` socket boundary. To guarantee absolute sub-millisecond precision irrespective of Swift thread-pool execution delays, the core engine leverages **Hardware-Level Kernel Timestamping** via Unix `SO_TIMESTAMP` in `recvmsg()`. This enables the extraction of `cmsghdr` payload timestamps directly from the physical Network Interface Card (NIC) interrupts—accurately logging true physical packet jitter without artificially skewing our 1-FPS forensic extraction timing or being choked by high-CPU process scheduler starvation.
   - The application relies entirely on Apple’s **SwiftData** framework, bypassing third-party ORMs like Vapor’s Fluent. 
   - Uses the `@Model` macro to asynchronously inject `VideoLog` definitions natively into local `ModelContext`, triggering `@Observable` view rebuilds flawlessly across threads.
   - **Intelligent Rate Limiting**: To prevent dashboard starvation and database clutter, "OK" health telemetry events are smartly suppressed using deterministic Wall-Clock Delta Tracking. OK events are mandated to emit strictly every 10 real-world minutes during prolonged periods of normal operation. The engine implements strict state tracking using mandatory 3-second safety buffers following initial startups or immediate incident recoveries to combat erratic telemetry flapping.

    - **Forensic PDF/CSV/JSON Exports**: The platform natively includes a local `DatabaseExporter` mapping `SwiftData` models direct to macOS `NSSavePanel` and CoreText paging for quick incident analysis formatting outputs without reliance on third-party libraries.

---

## 🚀 Getting Started

No Node.js or Vapor installation is required!

### 1. Requirements
Your system must have:
- **macOS 14.0** (Sonoma) or newer.
- **Xcode 15+** installed to properly compile SwiftData macros.
- **Hugging Face Account**: The vision pipeline relies on native `mlx-swift` to run Gemma 4 models.
  - You must accept the Gemma model agreements on [Hugging Face](https://huggingface.co/google/gemma-4-e2b-mlx-4bit).
  - You must generate a Hugging Face Access Token (with "Read" permissions).
  - Before compiling the application, you must export your token as an environment variable (`export HF_TOKEN="your_token"`). The build script will automatically securely download the 6GB Gemma model natively into the `.app` bundle, allowing the interface to function completely offline without asking the user for API keys!
 
### 2. Run the Application natively (macOS)

You do not need an Xcode project (`.xcodeproj`) file! Modern Xcode securely comprehends the `Package.swift` hierarchy perfectly.

1. Open a terminal and run the initial model download script:
   ```bash
   cd mac-frontend
   export HF_TOKEN="your_huggingface_read_token"
   ./Scripts/download_model.sh
   open -a Xcode Package.swift
   ```
2. Wait a brief moment for Xcode to recursively resolve the internal package graph.
3. In the top toolbar, ensure the Scheme is set to **`EyesOnGlass`** (the tool icon) and the target destination is set to **`My Mac`**.
4. Press **`Cmd + R`** to Build and Run! 

The glassmorphic macOS application will appear instantly, granting you access to initialize the `LiveStreamService` natively over `UDP`.

### 3. Automated Validation Framework (CLI Battery Test)

In accordance with our Code-Style Guidelines (Autonomous Execution, Testing, and Quality Standards), the project features a fully decoupled, headless `Executable` testing harness designed to validate anomalies. 

**True Live Simulation:** The offline extraction logic has been replaced entirely with `SimulatedLiveService`. Rather than slicing static files to disk, the validation engine now securely boots a background FFmpeg instance and broadcasts local video sets directly into Apple's Network Framework at exactly 1x real-time speed. This fundamentally guarantees that CLI battery tests execute against the exact same UDP payload dynamics, memory limits, and timing constraints as production live streams.

**Asynchronous VLM Hold Telemetry:** To accurately replicate the non-blocking execution of the background MLX Large Language Model validation, the CLI runner injects a trailing wait mechanism (`isStageAVerifying`). Tests are guaranteed to remain indefinitely blocked and will not export logs or automatically truncate local background extraction loops if a suspected visual incident (e.g. macroblocking) has tripped an async evaluation, resolving intermittent test result disparities.

To execute the validation engine natively against the `.e4b` MLX architecture locally, supply your Hugging Face Authentication Token as an environment variable:
```bash
cd mac-frontend
swift build
./Scripts/build_metal_shaders.sh # Required: Compiles Native MLX Metal Shaders
ANALYSIS_CLI=true HF_TOKEN="your_huggingface_read_token" ./.build/debug/EyesOnGlass --cli
```
*(This directly pipes all live-streaming telemetry and VLM evaluations into a standalone `analysis_results/analysis_results_<timestamp>.json` log upon completion of the stream broadcast.)*

### 4. Packaging the Application for Distribution

Because `Package.swift` builds a raw executable, Xcode's standard **Product > Archive** framework is disabled. If you want to bundle the application into a properly structured macOS `.app` bundle, use the included packaging scripts:

1. Open a terminal and navigate to the frontend directory:
   ```bash
   cd mac-frontend
   ```
2. Run the packaging shell script:
   ```bash
   ./Scripts/package_app.sh
   ```
3. A fully constructed `EyesOnGlass.app` bundle will be generated in the root of the `mac-frontend` folder, complete with a nested `Info.plist`, compiled macOS resources, and ad-hoc code-signing!

### 4. Automated Testing

The Swift Package Manager contains unit tests targeting the new Application layers. 

From terminal:
```bash
cd mac-frontend
./Scripts/build_metal_shaders.sh # Ensures the MLX Metal shaders are present in the test cache
swift test
```
Or use the native `Cmd + U` shortcut directly within Xcode.

### 5. UDP Throughput Load Testing

For benchmarking the absolute multi-core boundaries of Apple Silicon, we run a native, pace-limited UDP localhost load test. This `LiveMulticastLoadTest` executes directly against the `UDPIngestor` actor using Apple's `Network.framework` to determine raw `MB/sec` capacity metrics of the native extraction engine:

```bash
cd mac-frontend
swift test --filter LiveMulticastLoadTest
cat /tmp/live_multicast_result.txt
```

---

## 🔮 Future Enhancements
- **Enhanced Data Retention**: Export `SwiftData` logs into iCloud via `CloudKit` syncing across multiple observer devices.
- **Remote Telemetry Dashboards**: Implement secondary streaming metrics locally through Swift Charts.
