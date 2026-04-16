# Brainstorming Design: Resolving Telemetry Queue Backpressure

## Understanding Summary
- The application suffers from delayed UI events (e.g., `TOP ARTIFACT` appearing minutes after detection).
- Events flush heavily to the UI strictly *after* the UDP ingestion stream halts, indicating severe thread execution backlog.
- Video playback suffers Decoder failures (`-12909`), but this specific document addresses the architectural event backlog.
- The root cause is `try? context.save()` running synchronously on the `@MainActor` for every single issue identified by `LiveStreamService`. 
- Because `LiveStreamService` waits using `await streamController.insertVideoLog(...)`, the actor gets suspended infinitely behind heavy disk I/O, queuing hundreds of tasks in memory.

## Assumptions
- Removing per-frame SQLite disk-writes will instantly resolve the ingestion actor lockup.
- SwiftUI `@Query` structures will immediately detect and render `context.insert()` without requiring a synchronous database `save()`.
- It is acceptable to slightly debounce the rigid disk saving to 5-second intervals to optimize system bus I/O latency.

## Decision Log
- **What was decided:** Implement a "Fire-and-Forget Logging & Debounced Saves" architecture.
- **Alternatives considered:**
  - *Background SwiftData ModelActor:* High architectural purity, but introduces massive complexity trying to sync secondary database contexts with MainThread `@Query` updates safely.
  - *In-Memory Array Buffering:* Requires custom arrays and array-flushing locks resulting in non-fluid, stuttering UI updates.
- **Why this option was chosen:** Wrapping insertion closures in deferred `Task { @MainActor }` instantly frees the ingestor, while relying on SwiftData's memory-layer `@Query` keeps UI visually real-time. Debounced background saves retain absolute data safety with minimal risk.

## Final Design

1. **Unblocking the Ingestion Actor**
   Inside `LiveStreamService.swift`, all calls to `await streamController?.insertVideoLog(...)` will be replaced with:
   ```swift
   Task { @MainActor [weak self] in
       self?.streamController?.insertVideoLog(...)
   }
   ```
   This prevents the UDP thread from pausing to wait for the Main Thread to finish processing logs.

2. **Optimizing SwiftData Persistence**
   Inside `StreamController.swift`'s `insertVideoLog`, the line `try? context.save()` is removed. Calls to `context.insert(log)` will populate the view instantly without waiting for SQLite.

3. **Debounced Safety Save**
   A new `@MainActor func flushToDisk()` will be introduced inside `StreamController`. A simple background timer will trigger this once every 5-10 seconds to securely commit the in-memory context backlog to the permanent SQLite storage without grinding the processing gears.
