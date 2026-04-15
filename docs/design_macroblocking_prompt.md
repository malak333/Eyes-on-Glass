# Gemma 4 e4b Macroblocking Prompt Redesign

## Understanding Summary
* **What is being built:** A redesigned zero-shot negative-constraint prompt for the `stageAPrompt` in `NativeVLMClient.swift`.
* **Why it exists:** To shift the model's role to a "skeptical auditor" to eliminate false-positive macroblocking detections caused by sharp text overlays, logos, tickers, and natural motion blur in streams like `kabc`.
* **Who it is for:** The local *Eyes-on-Glass* pipeline running Gemma 4 e4b.
* **Key Constraints:** 
  * Must remain Zero-Shot (no examples) to preserve low latency and memory usage.
  * Must utilize the two-frame temporal context (Previous Frame vs. Suspected Frame).
* **Explicit Non-Goals:** We are not changing the underlying Swift inference logic, memory limits, or adding few-shot formatting overhead.

## Assumptions
* The Swift parser looks for `"detected": true/false`, so the new prompt must continue to output the exact JSON structure: `{"description": "...", "detected": true/false}`.
* We are specifically updating `stageAPrompt`, as it acts as the confirmation stage.

## Decision Log
* **Decision:** Modify `stageAPrompt` to use the "Algorithmic Gate" method rather than a Few-Shot method.
* **Why:** The algorithmic gate forces the model to reason structurally through possible false-positive scenarios (like text overlays or motion blur) before answering, which reduces false positives in the `kabc` stream without the latency or memory overhead of few-shot examples.
* **Decision:** Replaced the "step-by-step reasoning" instruction with a maximum 10-word summary requirement.
* **Why:** The VLM's full chain of thought was exceeding the 140 token limit set in `NativeVLMClient.swift`, causing the JSON to truncate before the `"detected"` key was printed, which led to valid macroblocking events being mistakenly rejected by the Swift JSON parser.
* **Decision:** Implemented a Hybrid Filter Approach. (OpenCV Variance Cap + VLM Ringing Filter)
* **Why:** The VLM was still occasionally overwhelmed by heavy graphic overlays in `kabc`. Capping allowable variance (e.g. `laplacianVariance > 400.0`) algorithms out the sharpest overlays early, conserving compute. Adding a negative constraint against "compression ringing" in the VLM prompt protects against stragglers.
* **Alternatives Considered:** Relying strictly on the algorithm (risked missing true blockiness) or strictly on the LLM (burned compute and allowed probabilistic misclassifications).

## Final Design (Target Prompt)
This prompt completely replaces the legacy `stageAPrompt` string inside `NativeVLMClient.swift`.

```swift
    public static let stageAPrompt = """
    You are an expert video quality auditor. Compare the provided chronologically ordered images (Frame A: Previous, Frame B: Suspected Issue).
    Your task is to determine if Frame B exhibits severe macroblocking (digital pixel starvation) compared to Frame A.

    Evaluation Gate:
    1. Look at the suspected blocky region. Is it a structural object like a sharp text overlay, logo, news ticker, or architectural line? If yes, it is NOT macroblocking.
    2. Are you seeing blockiness or digital noise hugging tightly around sharp text or graphics? This is standard compression ringing/noise, NOT a severe macroblocking incident. It is a false positive.
    3. Is the blurriness caused by natural high-speed motion between Frame A and Frame B? If yes, it is NOT macroblocking.
    4. Macroblocking ONLY appears as disjointed, blocky digital noise that unexpectedly corrupts underlying texture in moving areas.

    Reply exclusively in valid JSON format. Mentally evaluate the gate, but provide ONLY a concise, maximum 10-word summary of your reasoning in the description.
    {"description": "...", "detected": true/false}
    """
```
