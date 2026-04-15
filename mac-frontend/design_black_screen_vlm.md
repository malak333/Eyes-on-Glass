# Black Screen Arbitration Design

## Understanding Summary
*   **What is being built:** A temporal verification flow for black screen detection using the Gemma 4 E4B Vision-Language Model.
*   **Why it exists:** To eliminate false positives by distinguishing "technical black screens" (signal loss) from "creative black screens" (e.g., scene transitions, commercial breaks, ending credits).
*   **Who it is for:** Broadcast operators relying on the Eyes-on-Glass forensic pipeline who need high-confidence alerts, not noise.
*   **Key constraints:** OpenCV triggers the workflow. The system holds the alert for a timeout of up to 10 seconds, collects the preceding frame from the existing visual ring buffer along with the black frames and the restored frames, and sends them to Gemma for arbitration.
*   **Explicit non-goals:** We are *not* replacing OpenCV. OpenCV remains the lightweight primary scanner; Gemma acts as the final arbiter.

## Assumptions
*   **Performance / Latency:** Delaying black screen alerts by 5–10 seconds is acceptable because broadcast operators value avoiding false alarms more than sub-second notification speeds.
*   **Scale / Overhead:** Reusing the existing M-Series hardware-accelerated HEIC ring buffer (`visualRingBuffer`) introduces no new CPU/memory overhead.
*   **Memory Residency:** Gemma 4 E4B is already loaded into memory at the start of the application. There is no need for offline fallback logic regarding model loading failures.

## Decision Log
1.  **Trigger Mechanism:** Chose to use OpenCV as the trigger (Approach 1) rather than periodic VLM sampling or detached asynchronous task polling. *Why:* Aligns closely with the existing macroblocking architecture, maintains strict sequence guarantees, and ensures the VLM is only invoked when absolutely necessary to save power.
2.  **Context Buffering:** Chose to extract the *previous* frame (`preBlackScreenFramePath`) immediately upon first detection of a black screen from the pre-existing 30-frame HEIC ring buffer. *Why:* Zero added memory overhead and guarantees we have the exact visual context before the signal dropped.
3.  **VLM Fallback Policy:** Decided on a "fail-active" error handling strategy. If the VLM parses invalid JSON or hallucinates, the system will log the event as a confirmed technical failure. *Why:* In broadcast monitoring, a false positive is annoying, but a false negative (hiding a real blackout) is catastrophic.

## Final Design

### 1. State Additions in `LiveStreamService.swift`
We introduce the following state tracking variables into the `LiveStreamService` actor:
*   `isCurrentlyBlackScreen: Bool`
*   `blackScreenStartTime: TimeInterval?`
*   `preBlackScreenFramePath: String?`
*   `representativeBlackFramePath: String?`

### 2. Main Frame Processing Loop
Inside `processFrame(pixelBuffer:audioHealth:networkIAT:sessionName:thumbnailsDir:)`:

*   **Incident Initiation:** When `cv.isBlackScreen` evaluates to `true` and `!isCurrentlyBlackScreen`:
    *   Set `isCurrentlyBlackScreen = true`.
    *   Set `blackScreenStartTime = CFAbsoluteTimeGetCurrent()`.
    *   Cache the preceding clear frame using `getPreviousFrameHEIC()` into `preBlackScreenFramePath`.
    *   Cache the current frame as `representativeBlackFramePath`.
    *   *Crucially:* Suppress appending the `("black_screen", ...)` tuple to `issuesFound` at this stage.

*   **Incident Timeout Monitoring:** If `cv.isBlackScreen` remains `true` on subsequent frames:
    *   Check `(CFAbsoluteTimeGetCurrent() - blackScreenStartTime!) >= 10.0`.
    *   If exceeded: The timeout is hit. We package a `("black_screen", 1.0, "opencv", "Timeout exceeded without recovery", nil)` issue. We reset the tracker state because the broadcast is verifiably dead.

*   **Incident Resolution (VLM Arbitration):** When `cv.isBlackScreen` evaluates to `false` and `isCurrentlyBlackScreen == true`:
    *   The black screen has ended before the timeout.
    *   Save this current frame as the `restorationFramePath`.
    *   Reset `isCurrentlyBlackScreen = false` and other trackers.
    *   Spawn an asynchronous detached `Task` to call `NativeVLMClient.shared.analyzeBlackScreenTransition(...)`.

### 3. VLM Integration (`NativeVLMClient.swift`)
A new method `analyzeBlackScreenTransition(preFrame: String, blackFrame: String, endFrame: String, tier: VLMModelTier) async -> (isFailure: Bool, reason: String)` will be built.

*   It constructs a multi-modal prompt containing all three images in chronological order.
*   The prompt tasks Gemma with determining if this is a "creative transition" or a "technical failure".
*   If `isFailure == true` (or if parsing fails), the task logs the delayed incident to `StreamController`.
*   If `isFailure == false`, the task quietly drops the incident without notifying the UI.
