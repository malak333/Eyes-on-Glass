# Native MLX VLM Migration Design

## 1. Understanding Summary
- **What is being built:** A native replacement for the Ollama inference engine in the `Eyes-on-Glass` macOS application. We are integrating `mlx-swift` to run Google's Gemma 4 VLM family directly on Apple Silicon.
- **Why it exists:** To eliminate the need for an external Ollama daemon (and Docker), simplify the architecture, maximize native Apple Silicon performance (unified memory), and ensure a fully self-contained application.
- **Who it is for:** Users of the Mac frontend needing fast, local, and private AI detection of stream issues like static slates.
- **Key constraints:** The pipeline must support dynamic runtime configuration for switching between Gemma 4 E2B, E4B, 26B-A4B, and 31B depending on the user's hardware. Model loading times must not cause the application to crash or behave incorrectly. Streaming cannot begin until the model is localized and fully resident in memory.
- **Explicit non-goals:** Creating our own vision models from scratch, or communicating with cloud-hosted LLM APIs. This remains a strictly on-device architecture.

## 2. Assumptions
- **Model Weights Delivery:** The application will handle downloading the required MLX weights from the Hugging Face Hub on demand when a new model is selected. We will not bundle the models in the Xcode package.
- **Swift Package Manager:** We will add Apple's `mlx-swift` and `mlx-swift-examples` (or hub components) as dependencies in the `Package.swift`.
- **Data Format:** We will maintain the existing prompt requirement that the LLM payload returns strict JSON (`is_slate` boolean, `confidence` float) to minimize downstream regressions.
- **Precision:** We will default to downloading and executing the 4-bit quantized versions of the Gemma 4 multimodal models.

## 3. Decision Log
| Decision | Alternatives Considered | Rationale |
| :--- | :--- | :--- |
| **Use HuggingFace Hub for Model Loading** | Sideloading models via an "Import Folder" UI | Sideloading requires manual user intervention and is prone to errors (selecting wrong models or non-quantized weights). On-demand loading is much more user-friendly and automates proper weight retrieval. |
| **Pre-stream Model Isolation** | Allowing the stream to start but bypassing AI frames while downloading | Live streaming is resource-intensive. Trying to download gigabytes of data and allocate heavy system memory *while* processing UDP streams introduces instability. Blocking the stream start prevents race conditions. |
| **Configurable Model Tier Selection** | Hardcoding to `E2B/E4B` or exclusively requiring `26B-A4B` | Different Mac hosts have wildly different Unified Memory sizes (8GB up to 192GB). Offering all 4 tiers (E2B, E4B, 26B, and 31B) allows scaling from an M1 MacBook Air up to an M3 Ultra Mac Studio cleanly. |

## 4. Final Design

### Architecture & Components
1. **Dependency Management:** Update `mac-frontend/Package.swift` to include `mlx-swift`.
2. **The New Client:** Create a new Swift Actor named `NativeVLMClient` to completely replace `OllamaClient`.
3. **Configuration Enum:** Introduce a `GemmaModelTier` enum representing `e2b`, `e4b`, `26b`, and `31b`, mapping directly to their huggingface local repo IDs.
4. **Memory Isolation:** As an actor, `NativeVLMClient` ensures models are loaded serially, preventing data races if two threads ever attempted to load the multi-gigabyte models concurrently.

### Data Flow & UI State
1. **Gatekeeping the Stream:** In `DashboardView` (or wherever configuration is held), "Start Livestream" is gated behind an `isModelReady` state. If the selected model is not localized, the button changes to "Download & Prepare Model".
2. **Observability to the UI:** `NativeVLMClient` will use Observation to broadcast properties such as `downloadProgress` and `state` (`.downloading`, `.loading`, `.ready`, `.error`).
3. **Zero-Copy Intent:** Currently, the system writes frames to `.jpg` on disk and `OllamaClient` reads them. Moving forward, the goal will be to pass these localized image URLs or buffers directly into the MLX bindings.

### Error Handling & Edge Cases
1. **Download Resiliency:** The Hub download client caches chunks. If network connectivity fails, the UI will reflect an `.error` state and allow the user to easily restart the download.
2. **Out-of-Memory (OOM) Fallbacks:** Before triggering a load of the `31B` or `26B-A4B` models, the system will read current `os_proc_available_memory()`. If the user has insufficient hardware memory, it will preemptively warn them and gracefully fallback rather than causing a severe crash.
