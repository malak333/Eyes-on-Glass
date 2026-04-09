# Eyes on Glass

**Eyes on Glass** is an AI-powered concept application that monitors video streams (e.g., `.ts`, `.mp4`) for visual/audio anomalies like lip-sync issues, macroblocking, pure black screens, slates, top artifacts (e.g., tearing, VANC data bleed), and audio corruptions (like audio dropouts, severe buzzing, or sporadic clicking audio). Instead of monitoring the stream at a full 60 FPS, this application extracts an optimized subset of frames (1 FPS) for analysis, drastically improving performance while retaining fidelity, designed explicitly to run on local hardware (e.g., M1 Pro with 32GB of RAM).

---

## 🏗 Architecture

The platform architecture is highly localized and split into a React Frontend and Python Backend:

1. **Frontend (`frontend/`)**: 
   - A Vite + React web application properly unit-tested via **Vitest**.
   - Designed with an ultra-premium aesthetic utilizing raw CSS glassmorphic overlays.
   - Monitors timeline intelligence, live stream health scores, and dynamic internal hardware consumption (CPU, Memory, GPU) separated into dedicated visual charts.
   - Features a real-time system polling indicator that actively monitors if the local Ollama daemon is properly running.
   - Features dynamic tabbed navigation to seamlessly switch between the currently analyzed "Active Stream" and previously generated "Old Analysis" history logs.
   - Displays a live, asynchronous **Progress Tracking Bar** during video uploads so you can monitor extraction and processing status.
   - Includes a dynamic **Analysis Breakdown** summary detailing every specific anomaly detected (e.g., Macroblocking, Lip Sync, Audio Dropouts) broken down by total frame count.
2. **Backend (`swift-backend/`)**:
   - A high-performance **Swift Vapor** service running natively on Apple Silicon.
   - Receives video streams asynchronously natively bypassing the former Python GIL bottlenecks.
   - Delegates local processing to **AVFoundation/AVAssetReader**, carving out frames directly into memory, dramatically outscaling sub-process FFmpeg extraction speeds. If a broadcast transport stream contains malformed headers (e.g., missing PPS/SPS configurations) that crash hardware decoders, a robust extraction subsystem seamlessly falls back to a sub-process **FFmpeg Decoder Engine** automatically retrieving frames for structural fidelity.
   - Feeds extracted frames concurrently using Swift's `async let` and `TaskGroup` primitives (scaled dynamically to `activeProcessorCount * 2`) into a **Native Validation Pipeline**. Math matrix routines executed natively via `vImage` and `Accelerate` check for standard deviation and laplacian threshold differences replacing heavyweight OpenCV libraries. The native Core Audio loop scans for decibel peaking, muting, and zero-cross clipping on RAW buffers.
   - **Analysis Engine Tracking**: Every detected issue is securely tagged directly to the specific execution engine (`avfoundation`, `coreimage`, `ffmpeg`, `quick_ai`, or `heavy_ai`) to grant engineers precise debugging observability.
   - Only beautifully clean frames fall through to the **AI Analyzers**, which dynamically orchestrate a tiered approach using **Ollama Vision Language Models**: checking the lightweight **Moondream** model first for high-speed anomalous slate detection before defaulting to the heavier **LLaVA** model as a final assurance check.
   - Implements an asynchronous system polling task using macOS `mach_task` primitives alongside `powermetrics` natively within Swift to stream live operational hardware telemetry back to the dashboard.
   - **Live Multicast Integration (`LiveStreamService`)**: A dedicated concurrent actor natively ingests infinite UDP streams (`udp://@...` or unicast `udp://127.0.0.1...`) using low-level **BSD Sockets** and Swift `AsyncStream` pipelines (`UDPIngestor`). Processing is strictly sequential and synchronous on the actor: manually demuxing MPEG-TS packets into raw Network Abstraction Layer (NAL) units (`TSDemuxer`), extracting arrays of discrete `TSDemuxerEvent` types, and executing zero-copy, hardware-accelerated video decoding via Apple Silicon's native VideoToolbox (`H264Decoder`). All high-frequency bridging operations across Core Media C-APIs are aggressively flushed via highly-localized `autoreleasepool` closures to guarantee constant-time memory ceilings during continuous pipeline operation. This rigorous deterministic order strictly guarantees NAL bitstream integrity before initialization and eliminates the previous heavy `ffmpeg` sub-processes while retaining strict 1 FPS bounds. *Note on local testing: Due to macOS kernel restrictions on BSD sockets dropping local multicast packets, local `ffmpeg` streams must be natively targeted to loopback unicast (`udp://127.0.0.1:4001`) rather than multicast.*
   - **Deprecated Python Core**: The previous experimental FastAPI backend pipeline code remains inside `backend/` strictly for historical reference and Python data-science testing pipelines (i.e. `tests/run_swift_battery.py`).
3. **Log Aggregator**:
   - Simulated network ingestion logs (originating from combinations of Source Nodes, Backbones, and Distro Dests) are logged inside a local persistent **SQLite** database (`backend/sqlite.db`), tracked exclusively via **Swift Fluent ORM**.

---

## 🚀 Getting Started

The platform runs two distinct services natively.

### 1. Requirements
Ensure you are running **Python 3.10+** and **Node 18+**. 
Your system must also have `ffmpeg` installed to extract and process streams. 

To enable the AI vision analysis, you will also need to have **Ollama** installed on your system running the `moondream` and `llava` vision language models:
- `brew install ollama`
- `brew services start ollama`
- `ollama pull moondream`
- `ollama pull llava`

*(Note: Using `brew services start ollama` registers Ollama as a background daemon that runs continuously and starts automatically on reboot. You do not need to manually start it alongside the backend/frontend scripts. If Ollama is unavailable, the pipeline gracefully falls back to a simulated "OK" state without crashing)*

### 2. Run the Production Backend

The backend has been ported purely to Swift Vapor for robust Apple Silicon compatibility!
To launch the backend seamlessly, use the dedicated bash integration script located at the project root:

```bash
./start_production.sh
```

This officially mounts the API interface globally.
*(Note: Extracted anomalies will populate locally into `backend/thumbnails`.)*

> **Hardware Telemetry Warning**: To access real macOS Apple Silicon **GPU % utilization metrics** inside the dashboard's System Resources graph, the `start_production.sh` script automatically wraps the final Swift binary trigger in `sudo`. This unlocks proper execution of `powermetrics`. The background telemetry securely inherits the host process's root privileges without requiring any secondary credentials or `.env` configuration files.

### Networking & Limits
- **CORS API Middleware**: The Vapor engine emits Cross-Origin Resource Sharing (CORS) headers by default. This permits any external frontend (like Vite running on `localhost:5173`) to seamlessly pipe payloads directly into `127.0.0.1:8080` without experiencing browser blockage.
- **Payload Constraints**: Vapor's default 16MB file threshold has been aggressively scaled up. The core effectively eats payload sizes of up to **1GB**, allowing raw TS and MP4 ingest functionality without HTTP 413 drops.

### 3. Run the Web Dashboard

Open a separate terminal and navigate back to the project root.

```bash
cd frontend
npm install
cd ..
./frontend/run.sh
```
Alternatively, just execute `./frontend/run.sh` from the root directly on subsequent runs.
Navigate to `http://localhost:5173`. 
You can use the **"Monitor Stream"** button to dispatch local `.ts` and `.mp4` video elements directly into the AI parsing pipeline.

### 4. Run the Tests

A solid testing baseline exists for both the React dashboard and the FastAPI orchestration backend. Furthermore, a CI pipeline is active under `.github/workflows/test.yml` to trigger concurrent Ubuntu execution agents on push.
To locally verify project fidelity:
- **Backend Test Suite**: `cd backend && source .venv/bin/activate && PYTHONPATH=. pytest tests/`
- **Frontend Test Suite**: `cd frontend && npm test`
- **Platform Integration Battery**: `cd tests && python3 run_swift_battery.py`

---

## 🔮 Future Enhancements (By 2026)
- **Real-time Pipeline**: Connect the Python ingest module directly to live ingest servers (SRT / UDP multicasts) rather than static file uploads.
- **Enhanced Data Retention**: Export logs for large-scale viewing using Prometheus/Grafana combinations.
