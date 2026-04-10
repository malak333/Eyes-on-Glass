# UI Modernization Design

## Understanding Summary
- **What is being built**: A complete visual modernization of the `mac-frontend` SwiftUI interface (specifically the Dashboard and Event Details views).
- **Why it exists**: To elevate the application from a raw "cyber/terminal" aesthetic to a premium, professional Apple-native macOS software experience.
- **Who it is for**: Operators monitoring the real-time video telemetry processing pipeline.
- **Key constraints**: Must strictly adhere to Apple's Human Interface Guidelines standards (SF symbols, semantic colors, proper typography weights).
- **Explicit non-goals**: No modifications to the underlying `SwiftData` schema, UDP ingestion logic, or media decoding pipelines. This is exclusively a presentation-layer upgrade.

## Assumptions (Non-Functional Requirements)
- **Performance & Scale**: The UI receives high-frequency updates and must scroll smoothly even with hundreds of logs. We utilize native performant structures like `List` and `AsyncImage`. 
- **Maintenance (Light/Dark Mode)**: By stripping out hard-coded hex colors and relying entirely on macOS semantic system colors (e.g., `.windowBackgroundColor`), the application will seamlessly and automatically support both Light and Dark system appearances.
- **Security & Data**: All telemetry processing and image files remain strictly on the local hardware.
- **Reliability**: Any missing or corrupted thumbnails will fallback gracefully using elegantly styled standard SF Symbols.

## Decision Log

| Decision | Alternatives Considered | Rationale |
| :--- | :--- | :--- |
| **Approach A: NavigationSplitView** | Approach B: Custom VStack/HStack Dashboard (Current style) | `NavigationSplitView` provides the most standard, recognizable Apple-native macOS layout. It is highly extensible for future tabs (like History) and offloads layout complexities to the OS. |
| **SF Pro over Monospaced** | Keeping `.font(.system(design: .monospaced))` globally | SF Pro is cleaner and explicitly native. We will tactically use `.monospacedDigit()` strictly for dynamically changing numbers (like CPU % and PTS) to prevent horizontal jitter while retaining high legibility for text. |
| **Semantic Colors over Hardcoded** | Retaining `Color.black.opacity(...)` styles | Semantic colors (like `.secondary` and `.controlBackgroundColor`) automatically adapt seamlessly to both Light Mode and Dark Mode without introducing complex conditional layout logic. |
| **Native `List` over `LazyVStack`** | Retaining custom `LazyVStack` nested inside a `ScrollView` | A native `List` provides standard macOS row highlighting, selection states, standard padding, and efficient rendering semantics for free out of the box. |
| **`LabeledContent` for Metrics** | Retaining the custom `MetricRow` `HStack` components | Apple's built-in `LabeledContent` component natively aligns label/value pairs cleanly, reducing custom structural code while perfectly matching standard macOS form layouts. |

## Final Design Specification

### 1. Architecture & Component Mapping
- **Root Shell**: The outer `VStack`/`HStack` grid in `DashboardView` will be replaced with a native macOS `NavigationSplitView`.
- **Sidebar (Left Panel)**: This acts as the command center. We will use native macOS `List` and `Section` components to logically group controls. Section 1 will be "Connection" (URI input and button). Section 2 will be "Hardware Acquisition" (timeframe picker, CPU, Memory, GPU metrics).
- **Detail Area (Right Panel)**: The central dashboard holding the live pipeline observability data inside a standard macOS `List`. Contains a native Toolbar indicating active Stream status.
- **Interactions**: Tapping a row in the right panel opens the `EventDetailView` in a standard native `.sheet` modal window, allowing easy dismissal while preserving visual context of the live feed beneath it.

### 2. Styling & Presentation Details
- **Typography Hierarchy**: Replace all explicit sizes with Swift's semantic system sizing (`.title`, `.headline`, `.subheadline`, `.caption`).
- **Materials**: Leverage native `.backgroundStyle(.background)` and `.secondary` foreground styling.
- **Media**: Thumbnails inside the List will feature a gentle `.clipShape(RoundedRectangle(cornerRadius: 8))` with a subtle translucent stroke border for visual definition.
