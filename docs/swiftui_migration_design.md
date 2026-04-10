# SwiftUI Frontend Migration Design

## 1. Understanding Summary
- **What is being built:** A native macOS desktop application using SwiftUI, specifically optimized for Apple Silicon, to replace the existing React/Vite web dashboard.
- **Why it exists:** To maximize performance, completely unify the codebase in Swift, and leverage deep access to macOS APIs (direct Metal rendering, native hardware telemetry) without browser/Electron overhead. 
- **Who it is for:** Local operators, QA personnel, and engineers running the "Eyes on Glass" application on high-end Apple Silicon hardware.
- **Key Constraints:** Must retain an ultra-premium "glassmorphic" aesthetic, easily hook into the local Ollama daemon for AI routines, and handle highly asynchronous, real-time data flows without UI stuttering.
- **Explicit Non-Goals:** No support for iOS/iPadOS wrappers or cross-platform desktop frameworks (Windows/Linux).

## 2. Assumptions (Non-Functional Requirements)
- **Performance Expectations:** UI must render smoothly at 60/120Hz. Memory footprint must be substantially lower than running a Chromium/V8 context.
- **Scale:** 1:1 local desktop tool for a single user, processing dense, high-frequency data arrays seamlessly.
- **Security/Privacy:** Strict local execution. Hardware telemetry tracking will rely on native macOS permissions, inheriting local trust without remote connectivity.
- **Reliability:** UI must be crash-resilient; if backend components bottleneck, the native UI context must remain decoupled and fully responsive.
- **Maintenance:** Sunsetting the Node.js/npm ecosystem for this project. Maintenance moves entirely to Xcode, SPM, and the Swift toolchain.

## 3. Decision Log

### Decision: Architectural Model
- **What was decided:** We will adopt a Single Unified Application Bundle. The backend ingestion engines (`UDPIngestor`, `TSDemuxer`, AI routines) will be merged out of Vapor directly into the SwiftUI `.app` bundle.
- **Alternatives considered:** A strict client/server split keeping Xcode/SwiftUI entirely separate from the Vapor backend, communicating via HTTP/WebSockets.
- **Why this option was chosen:** A unified application eliminates network overhead and socket drops. Direct in-memory communication using Swift Concurrency provides the best performance density on Apple Silicon, requiring only one Xcode project to compile, profile, and maintain.

### Decision: Data Flow & Concurrency
- **What was decided:** Use `AsyncStream`s to pipe data from background extraction actors to a centralized `@Observable StreamController` operating on the `@MainActor`.
- **Alternatives considered:** Callbacks, NotificationCenter, or direct tightly-coupled method calls.
- **Why this option was chosen:** It provides strong concurrency isolation, preventing intense VideoToolbox frame decoding or UDP ingestion from blocking the main UI thread while ensuring the UI reacts seamlessly.

### Decision: Data Persistence
- **What was decided:** Replace Vapor's Fluent ORM with Apple's native SwiftData framework.
- **Alternatives considered:** Raw SQLite libraries or CoreData.
- **Why this option was chosen:** SwiftData operates perfectly with SwiftUI's `@Query` macros for reactive data rendering. It drastically reduces boilerplate code compared to CoreData or managing raw SQLite migrations.

## 4. Final Design Overview

**Core Services Layer (The Engine):** 
Background `actor` instances managing `LiveStreamService`, `TSDemuxer`, and `H264Decoder`. Vapor routing is completely stripped out.

**Presentation Layer (SwiftUI):**
A pure SwiftUI layer utilizing `WindowGroup` with components such as `DashboardView`, `StreamTelemetryView`, and `AnalysisHistoryView`. Heavy render tasks connect directly to local memory publishers.

**Error Strategy:**
State-driven error representations. If a pipeline crashes (e.g. Ollama daemon dropout), actors emit fallback `.aiServiceUnavailable` statuses enabling the UI to throw aesthetic glass overlays without tearing down the underlying session state, facilitating auto-recovery.

**Testing Strategy:**
Dependency-Injected XCTest framework verifying `StreamController` reactions via MockStreamServices. System validations to optionally include XCUITest for native macOS component assertions.
