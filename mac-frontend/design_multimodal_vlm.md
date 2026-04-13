# Multimodal VLM Pipeline Design

## Understanding Summary
- **What is being built:** Standardization and bug resolution of the Automated CLI Battery Test across 29 specific reference media files using the Gemma 4 E4B model.
- **Why it exists:** To guarantee the `EyesOnGlass` validation framework reliably detects visual and auditory stream anomalies (e.g., macroblocking, audio dropouts, syncing issues) without manual QA.
- **Who it is for:** Development team and CI/CD pipeline environments.
- **Key constraints:** Must prioritize catching expected anomalies (avoiding false negatives) and gracefully recover from corrupted frames or decoder failures.
- **Explicit non-goals:** Absolute elimination of false positive detections, real-time UI/frontend performance optimization, or testing against superseded models (e.g., Gemma 2/B26).

## Assumptions
- Execution speed is secondary to accurate anomaly detection.
- `HF_TOKEN` must be securely handled entirely in-memory and omitted from logging.
- Any unexpected decoder failures on an individual test asset should safely log the failure and attempt the remaining files rather than terminating execution.
- Gemma 4 E4B natively supports soft audio token ingestion (128-bin Mel Spectrogram at 16kHz) directly synchronized with visual frames, eliminating the need for audio-to-text bridging.

## Decision Log

### 1. Unified Architecture Approach
- **Decided:** Unified Multimodal VLM Injection.
- **Alternatives Considered:** Sequential Targeted Modalities (doing separate audio and visual ML queries) and Tiered Multimodal Prompting (chaining questions based on initial responses).
- **Why Chosen:** Because the Gemma 4 E4B mlx-swift-lm v3.x Processor natively aligns audio soft tokens with frame buffers, splitting the pipeline is unnecessary. A unified approach allows the model to analyze context temporally (resolving "lip sync" bugs naturally) while being highly efficient.

### 2. Audio Processing Pipeline
- **Decided:** Leverage the `MLXAudio` package purely to convert the extracted `.ts` audio blocks into a 128-bin Mel Spectrogram at 16kHz.
- **Alternatives Considered:** Routing audio telemetry into `LiveStreamService` natively with `vDSP`, or transcribing speech using Whisper.
- **Why Chosen:** User explicitly defined that Gemma 4 E4B supports raw mel spectrogram inputs as soft tokens, bypassing outdated constraints.

### 3. Parsing and Anomaly Fallbacks
- **Decided:** Implement a strict Swift `Codable` JSON schema constraint parsed dynamically, eliminating coerced regex matching. Handle total decoder failures by piping silent or black-frame context into the VLM to guarantee valid analysis outputs.
- **Alternatives Considered:** Maintaining the current regex-fallthrough logic in `NativeVLMClient`.
- **Why Chosen:** The VLM needs to identify over 9 unique anomalies (from "audio clicking" to "frozen screen"). Hardcoding string heuristics for every failure is unmaintainable; a strict `[{"type": "...", "confidence": 0.99}]` paradigm provides high stability.

## Final Design
The updated `NativeVLMClient` will process an interleaved sequence by passing an array of `Data` (frames) and a single formatted `AudioBuffer` directly to the processor. The generic `macroblockingPrompt` will be heavily rewritten to outline the exact JSON output requirement and explicitly demand the engine check for complex temporal/audio events (like lip sync decoupling, static noise, and signal loss drops). The extraction pipeline surrounding it will be insulated with catch-blocks to prevent a single file failure from terminating the battery sequence.
