# Eyes on Glass

**Eyes on Glass** is an AI-powered concept application that monitors video streams (e.g., `.ts`, `.mp4`) for visual/audio anomalies like lip-sync issues, macroblocking, pure black screens, slates, and audio corruptions (like audio dropouts or severe buzzing audio). Instead of monitoring the stream at a full 60 FPS, this application extracts an optimized subset of frames (1 FPS) for analysis, drastically improving performance while retaining fidelity, designed explicitly to run on local hardware (e.g., M1 Pro with 32GB of RAM).

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
2. **Backend (`backend/`)**:
   - A robust **FastAPI** server orchestration pipeline. 
   - Receives video streams and executes a **Two-Tiered A/V Sync Test** analyzing the internal Presentation Time Stamps (PTS) via `ffprobe`, catching audio drift and multiplexing failures synchronously.
   - Delegates local processing to **FFmpeg**, which carves out 1 FPS frame thumbnails efficiently.
   - Feeds extracted thumbnails sequentially into a **Cascading Verification Pipeline**, where OpenCV and FFmpeg instantly short-circuit and flag deterministic errors across two independent, concurrent tracks. The Audio Track detects silencing and buzzing, while the Video Track spots macroblocking and black screens without interrupting the other.
   - **Analysis Engine Tracking**: Every detected issue is securely tagged directly to the specific execution engine (`ffmpeg`, `opencv`, `quick_ai`, or `heavy_ai`) to grant engineers precise debugging observability.
   - Only beautifully clean frames (free of CV-level video issues) fall through to the **AI Analyzers**, which dynamically orchestrate a tiered approach using **Ollama Vision Language Models**: checking the lightweight **Moondream** model first for high-speed anomalous slate detection before defaulting to the heavier **LLaVA** model as a final assurance check.
   - Implements an asynchronous system polling task using `psutil` and macOS `powermetrics` to stream live operational tracking back to the dashboard.
   - Automatically maintains real-time analysis progress state, proactively clearing stale DB logs and leftover thumbnail frames from duplicate file re-uploads to ensure accurate data reflection.
   - Natively verified via **Pytest** for fast operational safety checks without booting the entire stack.
3. **Log Aggregator**:
   - Simulated network ingestion logs (originating from combinations of Source Nodes, Backbones, and Distro Dests) are logged inside a local persistent **SQLite** database (`sqlite.db`), providing chronological mapping for every anomaly captured.

---

## 🚀 Getting Started

The platform runs two distinct services.

### 1. Requirements
Ensure you are running **Python 3.10+** and **Node 18+**. 
Your system must also have `ffmpeg` installed to extract and process streams. 

To enable the AI vision analysis, you will also need to have **Ollama** installed on your system running the `moondream` and `llava` vision language models:
- `brew install ollama`
- `brew services start ollama`
- `ollama pull moondream`
- `ollama pull llava`

*(Note: Using `brew services start ollama` registers Ollama as a background daemon that runs continuously and starts automatically on reboot. You do not need to manually start it alongside the backend/frontend scripts. If Ollama is unavailable, the pipeline gracefully falls back to a simulated "OK" state without crashing)*

### 2. Run the Backend API

```bash
cd backend
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
export PYTHONPATH=$PYTHONPATH:$(pwd)
python -m uvicorn app.main:app --host 0.0.0.0 --port 8000
```
This mounts the API interface globally.
*(Note: Extracted anomalies will populate locally into `backend/thumbnails`.)*

> **Hardware Telemetry Warning**: To access real macOS Apple Silicon **GPU % utilization metrics** inside the dashboard's System Resources graph, you will need to start the backend with root privileges. We have provided a helper script to do this automatically by managing the virtual context and `PYTHONPATH`. Simply execute `./backend/run_sudo.sh` from the project root instead of manually running `uvicorn`. If executed without `sudo`, the GPU component will fall back to an estimation curve.

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

---

## 🔮 Future Enhancements (By 2026)
- **Real-time Pipeline**: Connect the Python ingest module directly to live ingest servers (SRT / UDP multicasts) rather than static file uploads.
- **Enhanced Data Retention**: Export logs for large-scale viewing using Prometheus/Grafana combinations.
