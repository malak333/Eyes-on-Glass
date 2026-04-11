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
   - **Live Multicast Integration (`LiveStreamService`)**: A dedicated concurrent actor natively ingests infinite UDP streams using low-level **BSD Sockets**. Processing leverages a multi-track parsing engine (`TSDemuxer`) extracting and locking onto both Audio and Video payloads simultaneously along with exact 33-bit Presentation Time Stamps (PTS). The Video track executes zero-copy hardware decoding via Apple Silicon's native VideoToolbox (`H264Decoder`).
   - **Real-Time Audio Telemetry**: The audio stream is actively monitored via continuous payload analysis (supporting ADTS AAC, MP2, MP3, and AC-3 codecs). `AVAudioConverter` transforms incoming audio packets into `Float32` linear PCM, which is immediately handed to Apple's **Accelerate** (vDSP) framework to run zero-latency Fast Fourier Transforms (FFTs) and Phase Correlation computations. These signals are piped dynamically to SwiftUI canvases to render real-time Waveforms, Vectorscopes, and Audio Phase arrays at 30 fps.

3. **Analysis Engine (`mlx-swift` & Gemma 4)**:
   - Streams frames concurrently via standard Swift `Actor` execution loops. Math matrix routines executed natively via `vImage` and `Accelerate` check for laplacian threshold differences replacing heavyweight external dependencies.
   - All cleanly extracted frames fall through to **Native AI Analyzers (`mlx-swift`)** utilizing Hugging Face Hub downloads to natively run Google Gemma 4 Multimodal family directly in Unified Memory.

4. **Telemetry Logging (`SwiftData`)**:
   - The application relies entirely on Apple’s **SwiftData** framework, bypassing third-party ORMs like Vapor’s Fluent. 
   - Uses the `@Model` macro to asynchronously inject `VideoLog` definitions natively into local `ModelContext`, triggering `@Observable` view rebuilds flawlessly across threads.

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

### 3. Packaging the Application for Distribution

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
swift test
```
Or use the native `Cmd + U` shortcut directly within Xcode.

---

## 🔮 Future Enhancements
- **Enhanced Data Retention**: Export `SwiftData` logs into iCloud via `CloudKit` syncing across multiple observer devices.
- **Remote Telemetry Dashboards**: Implement secondary streaming metrics locally through Swift Charts.
