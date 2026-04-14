# Network IAT Design

## Understanding Summary
- **Current Behavior:** The application currently reports anomalous "HIGH IAT" spikes (~1000ms) for every frame when analyzing assets or live streams. 
- **Root Cause:** IAT calculation was implemented inside the `LiveStreamService.processFrame` forensic loop, which `StreamMonitor` intentionally paces at exactly **1 FPS** (1000ms wall-clock intervals). This caused every single frame processed to naturally breach the 40ms alert threshold.
- **Goal:** Accurately measure the true Inter-Arrival Time base on raw UDP packet ingress timings (or local file chunk reading) to detect genuine stream ingestion latency/jitter, while avoiding database flood by aggregating this metric mapped to our existing 1-FPS forensic extraction pacing.

## Assumptions
- We want to capture the **max packet IAT** during a given 1-second extraction window.
- Capturing kernel-level network gaps ensures we trace the exact moments a multicast link (or local file read) drops packets, without artificially polluting standard analysis operations.
- Reporting the Max IAT per 1-second forensic frame provides all the necessary telemetry fidelity without overloading the `VideoLog` database.

## Decision Log
- **Decision:** Extract raw UDP `packetIAT` natively inside `UDPIngestor` vs processing inside `StreamMonitor` or out-of-band alerts.
- **Alternatives Considered:** 
  - *StreamMonitor Delegation:* Rejected due to potential actor-crossing overhead where `UDPIngestor` would need to call `StreamMonitor` asynchronously for every packet burst.
  - *Asynchronous Out-of-Band Alerting:* Rejected due to severe risk of UI/DB spamming; network volatility could spawn hundreds of events per second outside normal processing buffers.
- **Why this was chosen:** Approach 1 (`UDPIngestor Aggregation & Callback Injection`) provides the highest measurement precision (capturing the gap raw before demuxing), keeps memory boundaries clean, and aligns perfectly with the 1FPS UI reporting restrictions.

## Final Design
1. **UDPIngestor Modification:** 
    - Introduce a private variable `windowMaxIAT: Double = 0.0`. 
    - Within `handleData(_ data: Data)`, compute the instantaneous packet IAT: `currentIAT = (now - previousPacketTime) * 1000.0`.
    - Apply constraints: `if currentIAT > windowMaxIAT { windowMaxIAT = currentIAT }`.
2. **Callback Adjustments:**
    - Update `UDPIngestor.start()` signature to modify `onFrame: @escaping (CVPixelBuffer, AudioHealth, Double) -> Void`.
    - Before `UDPIngestor` forwards the extracted 1-FPS frame upstream inside `StreamMonitor.setOnSynced`, it captures the local `windowMaxIAT`, resets it back to `0.0`, and passes the captured max to `LiveStreamService.processFrame`.
3. **LiveStreamService Adjustment:**
    - Expand `processFrame(pixelBuffer:audioHealth:networkIAT:sessionName:thumbnailsDir:)` to absorb the `networkIAT`.
    - Strip out the former `lastFrameProcessTime` difference calculation since latency is natively supplied.
    - Persist the upstream `networkIAT` to the `StreamController.updateIAT()` and evaluate it against the `> 40.0ms` rule.
