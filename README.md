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
   - **Live Multicast Integration (`LiveStreamService`)**: A dedicated concurrent actor natively ingests infinite UDP streams utilizing Apple's ultra-low latency **`Network.framework` (`NWConnectionGroup`)**. This shift permanently replaced standard explicit UNIX BSD socket bounds, guaranteeing instantaneous **zero-copy DispatchData datagram propagation** directly natively avoiding internal OS context boundaries! Processing leverages a multi-track parsing engine (`TSDemuxer`) powered by a **Zero-Allocation Cursor** to parse packets natively without invoking dynamic memory re-allocations. Real-time ingestion occurs transparently within strict `.userInitiated` Quality of Service bounds—legally confining video parsing and network frame propagation strictly to Apple Silicon Performance (P) Cores while seamlessly routing telemetry dumps to Efficiency (E) Cores (`.utility`) to prevent kernel-level UDP multicast buffer exhaustion. The Video track executes zero-copy hardware decoding via Apple Silicon's native VideoToolbox (`H264Decoder`). The `H264Decoder` strictly manages mapping formats dynamically—aggressively validating incoming Sequence (SPS) and Picture (PPS) Parameter Sets natively. If broadcast metadata spontaneously shifts, it proactively invalidates the `VTDecompressionSession` to explicitly flush the hardware's Decoded Picture Buffer (DPB), completely eliminating `no frame!` and `mmco: unref short failure` reference cascading errors caused by raw UDP packet drops.
   - **Real-Time Audio Telemetry**: The audio stream is actively monitored via continuous payload analysis (supporting ADTS AAC, MP2, MP3, and AC-3 codecs). AC-3 payload framing is rigorously mapped using static **ATSC A/52 standard guidelines** to prevent native buffer drops. `AVAudioConverter` transforms incoming audio packets into `Float32` linear PCM. This data is piped directly to Apple's **Accelerate (vDSP)** hardware to execute zero-latency Fast Fourier Transforms (FFTs), true-peak analysis, and hardware stereo-to-mono mixing via `vDSP_vasm`. These vectorized arrays are bound straight into SwiftUI canvases to render ultra-smooth Waveforms, Vectorscopes, Audio Phase measurements, and Channel Peaks at 30 fps without stalling Swift's main thread loop.

3. **Analysis Engine (Hybrid VLM Pipeline & Gemma 4 E4B)**:
   - To optimize extreme performance, the application implements a **Hybrid VLM Pipeline** pairing classical computer vision heuristics natively with State-of-the-Art Generative AI.
   - **OpenCV Junior Pre-Filter**: Streams frames concurrently via standard Swift `Actor` execution loops. Fast heuristics (like Laplacian variance and blockiness calculations) actively monitor stream health without invoking the LLM, flagging potentially anomalous frames cheaply.
   - **Hardware-Accelerated Ring Buffer**: A persistent 30-frame visual trail is dynamically maintained in memory. To minimize overhead, raw `CVPixelBuffer` frames are synchronously encoded into HEIC (High-Efficiency Image Container) formats utilizing Apple's M4/M5 hardware Media Engine.
   - **Gemma 4 "Senior Engineer" Validations**: Only when the OpenCV Pre-Filter exceeds explicit variance thresholds is the **Native AI Analyzer** triggered. An exclusive `mlx-swift` ChatSession pipeline interfaces with the dense `Gemma 4 E4B` tier (running natively in Unified Memory via Hugging Face Hub downloads) to thoroughly inspect the frame, evaluating whether the identified artifacts correctly represent genuine broadcast anomalies.
   - **Stateless Zero-Shot Inference**: To completely eliminate ambient GPU and Core processing overhead, the VLM operates entirely on-demand. Background cache polling has been disabled. When OpenCV escalates a potential incident, the Native VLM instantly reconstructs its MLX context utilizing raw snapshot frames directly from the hardware HEIC ring buffer. This enforces a strict zero-shot architectural boundary, preventing any hallucinated context leakage between isolated broadcast corruptions.

4. **Telemetry Logging (`SwiftData` & Rate Limiting)**:
   - The application relies entirely on Apple’s **SwiftData** framework, bypassing third-party ORMs like Vapor’s Fluent. 
   - Uses the `@Model` macro to asynchronously inject `VideoLog` definitions natively into local `ModelContext`, triggering `@Observable` view rebuilds flawlessly across threads.
   - **Intelligent Rate Limiting**: To prevent dashboard starvation and database clutter, "OK" health telemetry events are smartly suppressed using deterministic Wall-Clock Delta Tracking. OK events are mandated to emit strictly every 10 real-world minutes during prolonged periods of normal operation. The engine implements strict state tracking using mandatory 3-second safety buffers following initial startups or immediate incident recoveries to combat erratic telemetry flapping.

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
  - Open the Eyes on Glass application and enter this token into the "Hugging Face Token" secure field to download and prepare the models natively.

### 2. Run the Application natively (macOS)

You do not need an Xcode project (`.xcodeproj`) file! Modern Xcode securely comprehends the `Package.swift` hierarchy perfectly.

1. Open a terminal and run:
   ```bash
   open -a Xcode mac-frontend/Package.swift
   ```
2. Wait a brief moment for Xcode to recursively resolve the internal package graph.
3. In the top toolbar, ensure the Scheme is set to **`EyesOnGlass`** (the tool icon) and the target destination is set to **`My Mac`**.
4. Press **`Cmd + R`** to Build and Run! 

The glassmorphic macOS application will appear instantly, granting you access to initialize the `LiveStreamService` natively over `UDP`.

### 3. Automated Validation Framework (CLI Battery Test)

In accordance with our Code-Style Guidelines (Autonomous Execution, Testing, and Quality Standards), the project features a fully decoupled, headless `Executable` testing harness designed to ingest raw streams and perform asynchronous MLX-VLM inferences iteratively against actual MLX Gemma model weights. 

To execute the validation engine natively against the `.e4b` MLX architecture locally, supply your Hugging Face Authentication Token as an environment variable to securely fetch tensors from the Hub:
```bash
cd mac-frontend
swift build
./Scripts/build_metal_shaders.sh # Required: Compiles Native MLX Metal Shaders
ANALYSIS_CLI=true HF_TOKEN="your_huggingface_read_token" ./.build/debug/EyesOnGlass --cli
```
*(This directly pipes all telemetry and VLM output payload evaluations into a standalone `analysis_results.json` log for review.)*

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

---

## 🔮 Future Enhancements
- **Enhanced Data Retention**: Export `SwiftData` logs into iCloud via `CloudKit` syncing across multiple observer devices.
- **Remote Telemetry Dashboards**: Implement secondary streaming metrics locally through Swift Charts.
