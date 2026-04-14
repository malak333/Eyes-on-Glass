# OK Event Rate Limiting Design Document

## Understanding Summary
- **What is being built:** A rate-limiting and state-tracking mechanism for the application's "OK" health event within `LiveStreamService.swift`.
- **Why it exists:** The previous implementation blindly fired an "OK" event nearly every second when conditions were healthy, which overwhelmed the database and clogged up the monitoring dashboard.
- **Who it is for:** Operators and engineers managing the dashboard, ensuring they receive meaningful health telemetry without the noise.
- **Key constraints:** "OK" events must only be dispatched in three scenarios: 
    1) Upon stream start, utilizing a 3-second stability buffer.
    2) Upon an artifact clearing, utilizing an identical 3-second cooldown buffer.
    3) After 10 continuous minutes (600 real-world seconds) have elapsed since the last "OK" log with no intervening issues. 
- **Explicit non-goals:** We are not modifying how anomalies (macroblocking, latency, black screens) are detected, nor are we touching the VLM forensic reporting pipelines. 

## Assumptions & NFRs
- **Performance:** This change reduces overhead by replacing per-frame/per-second writes with simple, cheap time-delta checks. 
- **Scale:** Essential for prolonged broadcast streams, ensuring the underlying database (e.g., SQLite) logic doesn't bloat over standard 24/7 runtimes.
- **Reliability:** The 10-minute heartbeat is reliable and strictly dictated by wall-clock time passing (`Date().timeIntervalSince1970`), keeping the dashboard aware that the engine hasn't died.
- **Maintenance:** The state tracking variables (last event time, continuous healthy duration, etc.) are cleanly encapsulated within the existing `LiveStreamService` actor.

## Decision Log

### 1) Stability Buffer
- **Decided:** Implementing a 3-second buffer ensuring sustained stability after starts or incident recoveries before emitting the "OK" event.
- **Alternatives Considered:** 1) Logging immediately, 2) Very long cooldowns (10-15s).
- **Why:** Immediate logging risks rapid flapping. 10-15s creates too long of a psychological delay on the dashboard before health is confirmed. 3 seconds perfectly bridges accurate feedback without flapping.

### 2) Heartbeat Strategy Let
- **Decided:** A 10-minute heartbeat using strict real-world wall-clock time.
- **Alternatives Considered:** Frame count-based math (e.g., 18,000 frames).
- **Why:** Framerates can drop or fluctuate, decoupling real time from data processing time. Wall-clock provides absolute assurance the system hasn't crashed.

### 3) Implementation Method
- **Decided:** Continuous Wall-Clock Delta Tracking inside the `LiveStreamService.swift` actor logic.
- **Alternatives Considered:** Active state machine with explicit detached async Swift `Task` timers.
- **Why:** Detached timers demand heavy lifecycle management via tracking cancellation tokens. Delta math is far simpler, relies purely on deterministic `processFrame` invocations, and avoids data races. 

## Final Design

### Architecture & Variables
We will inject two robust state properties into `LiveStreamService.swift` functioning alongside `lastOkLogTime`:
*   `lastIssueEncounteredTime: TimeInterval = 0`
*   `isPendingRecovery: Bool = true` 

*Note: `startMonitoring()` fundamentally resets all three timestamps/booleans explicitly to initialize correctly upon reconnects to new streams.*

### Data Flow Execution (`processFrame`)
1. **Anomaly Detection Block:** Standard CV routines operate. If `issuesFound` flags anomalies or an audio drop gets registered, the system forcefully configures `lastIssueEncounteredTime = Date().timeIntervalSince1970` and `isPendingRecovery = true`.
2. **Healthy Delta Block:** For 100% clean frames, compute `Date().timeIntervalSince1970 - lastIssueEncounteredTime`.
3. **Execution Routing Block:** 
   * If `isPendingRecovery` is true & delta `>= 3.0`: Emit "OK", commit `isPendingRecovery = false`, stamp `lastOkLogTime`. 
   * If `isPendingRecovery` is false: Evaluate if `currentTime - lastOkLogTime >= 600.0`. If so: Emit "OK", stamp `lastOkLogTime`.
