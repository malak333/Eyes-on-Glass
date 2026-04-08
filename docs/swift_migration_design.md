# Swift Backend Migration Design

## 1. Understanding Summary
*   **What is being built:** A headless, high-performance Swift backend service to completely replace the current Python/FastAPI `backend` directory.
*   **Why it exists:** To drastically increase video processing speed (target: 2x-3x) and lower CPU/RAM consumption by tapping directly into AVFoundation, eliminating Python's Global Interpreter Lock (GIL) and multiprocessing bottlenecks.
*   **Who it is for:** Users leveraging local M1 Pro Apple Silicon hardware to monitor broadcast streams for A/V anomalies.
*   **Key Constraints:** The new Swift backend must expose the exact same API signatures so the existing Vite + React frontend dashboard is not broken and requires zero changes.
*   **Explicit Non-goals:** We are *not* building a native macOS desktop UI (SwiftUI app). We are *not* porting the Vision Language Models (Moondream/LLaVA) to CoreML in this phase.

## 2. Explicit Assumptions
1.  **Hybrid AI Architecture:** The Swift backend will perform all heavy lifting (orchestration, extraction, and CV-level deterministic checks) but will still make asynchronous HTTP calls to the local Ollama daemon for the generative VLM checks.
2.  **Database Persistence:** The Swift service will connect to the existing local `sqlite.db` using the exact same schema so historical "Old Analysis" logs persist seamlessly.

## 3. Decision Log
*   **Decided Architecture Phase 1:** Hybrid Native Framework Backend instead of a monolithic desktop App or maintaining partial Python logic. This leverages MacOS compute specifically where the load is highest (av extraction/frame rendering).
*   **Decided Framework:** **Vapor Framework**. Selected for its robust routing similarities to FastAPI, mature SQLite/Fluent ORM, and battle-tested SwiftNIO handling of multipart video chunks natively asynchronously.

## 4. Final Design

### Architecture & Core Components
*   **API & Orchestration Layer (Vapor):** 
    Controllers handle exact endpoints matching FastAPI (`/upload`, `/analysis-status`, `/system-stats`). Fluent ORM maps to the identical SQLite DB schemas to preserve cross-language log compatibility.
*   **Extraction Engine:** 
    A native `VideoProcessor` utilizing Apple's `AVAssetReader` and `AVAssetImageGenerator` directly decodes video inside the application memory layer rather than shelling out continuous sub-processes to `FFmpeg`.

### Data Flow & Concurrency
1.  **Ingestion & Staging:** Vapor secures multipart video file HTTP streams directly into secure temporary block storage.
2.  **Concurrent Checks (TaskGroup):**
    *   **Audio Track:** AVFoundation analyzes PCM data natively for static drops and audio failures.
    *   **Video Track:** Frame heuristics (blur/black screen/macroblocking) are routed natively through CoreImage/Vision instead of OpenCV to keep processing within the Apple Silicon optimized layer.
3.  **VLM Tiering:** Clean frames are queued for async POST requests to the separate local Ollama daemon via `URLSession`.

### Error Handling & Edge Cases
*   Ollama unreachable or crashing results in non-fatal "AI Incomplete" tags, avoiding full stream stalling.
*   Malformed transport streams (`.ts`) triggering AVFoundation decoding failures are safely caught and bubbled to the frontend as "Parse Failure".

### Testing Strategy
*   **Unit Tests:** Handled natively using `XCTVapor` to rapidly test ingestion controllers without network port friction.
*   **Mocks:** The Ollama client (`URLSession` logic) is abstracted behind a protocol, allowing purely deterministic local Mocks for instantaneous test completion.
*   **Verification (End-to-End):** The pre-existing Python testing script (`run_video_battery.py`) will remain operational and serve as the ultimate integration validation against the new Vapor HTTP ports.
