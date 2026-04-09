# Multicast Stream Ingestion (Live Monitoring)

This implementation plan bridges the Eyes-on-Glass system from static file analysis into real-time broadcast monitoring by adding support for infinite stream playback (e.g., `udp://@227.0.0.1:4001`) parsed natively through the `VisionAnalyzer` pipeline.

## Decision Log

Throughout the brainstorming phases, the following decisions were made:

- **Ingestion Mode:** Dedicated `LiveStreamService` using a piped `ffmpeg` stream (Selected over modifying `ExtractionService` to prevent file vs. live logic overlaps and testing breakages).
- **Session Lifecycle:** A single, continuous "Live Session" that runs until manually stopped via the UI.
- **Handling Dropouts:** The stream will automatically and indefinitely attempt to recover/reconnect if the network drops on the server side.
- **Concurrency:** We will restrict monitoring to exactly one stream at a time. Triggering a new stream will kill the incoming stream explicitly.
- **Logging Throttling:** Non-anomalous frames ("OK") will only trigger a database write if 60 seconds have elapsed since the last "OK" log, to maintain database hygiene during successful long broadcast runs.

## User Review Required

> [!IMPORTANT]
> Please review the proposed architecture and file modifications below to ensure they fully align with your expectations. Approve to begin the execution phase.

## Proposed Changes

### UI Components

#### [MODIFY] `VideoUploader.jsx` (or a structural rename to `MediaInput.jsx`)
- Overhaul layout to include a new tab or section for **Live Streaming**.
- Add a text input bound to state `multicastUri`.
- Add a "Start Monitoring" / "Stop Monitoring" button logic. 
- Fire asynchronous API calls to `POST /live/start` and `POST /live/stop`.

#### [MODIFY] `App.jsx`
- Ensure that the global Application State correctly honors active/inactive streams vs file logs (though they populate the identical `logs` endpoints).

---

### Backend Logic (Swift Vapor)

#### [NEW] `LiveStreamService.swift`
- Construct an `actor` singleton (`LiveStreamService.shared`).
- Methods: `startMonitoring(uri:String)`, `stopMonitoring()`.
- Implementation wraps `Process()` to launch `ffmpeg -i <uri> -r 1 -f image2pipe -vcodec bmp -` alongside a robust `while isActive` reconnection wrapper.
- Contains the "Last 60-second OK" logic checking frame status through a direct handoff to `VisionAnalyzer.analyze(...)`.

#### [MODIFY] `VideoController.swift`
- Mount new routes:
  - `routes.on(.POST, "live/start", use: startLiveStream)`
  - `routes.on(.POST, "live/stop", use: stopLiveStream)`
- Within `startLiveStream`, ensure we stop any previous session before launching the new session in the `LiveStreamService.shared`.

## Open Questions

None currently.

## Verification Plan

### Automated Tests
- Run `.github/workflows/test.yml` tests to ensure the new Swift imports and structures do not break existing file extractions in `ExtractionService.swift`.
- Run locally: `swift test` or `./start_production.sh` check for swift build success.

### Manual Verification
- Will launch a mock UDP stream on standard localhost (e.g. via `ffmpeg -re -i test.mp4 -c copy -f mpegts udp://127.0.0.1:4001`).
- From the UI, start monitoring `udp://127.0.0.1:4001`.
- Verify the UI reflects incoming errors and exact "OK" 1-minute markers without spamming.
- Halt the mock stream and ensure Swift logs an attempt to reconnect without crashing the HTTP server. 
- Manually click "Stop Monitoring" and verify the active `ffmpeg` daemon actually dies in Activity Monitor/CLI.
