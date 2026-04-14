# Brainstorming Design: Bundling Gemma Model

## Understanding Summary
- **What is being built:** An automated build process that removes the Hugging Face API key requirement from the UI and natively bundles the 6GB Gemma-4-E4B model directly into the application.
- **Why it exists:** To create a seamless, zero-configuration experience so the app works 100% offline immediately upon first launch by internal users.
- **Who it is for:** Internal deployment (trusted team members).
- **Key constraints:** Xcode compiling and archiving processes will take significantly longer to pull down and package the 6GB model. The final `.app` binary size will exceed 6GB.
- **Explicit non-goals:** We are not concerning ourselves with App Store size limits or protecting against token/model reverse-engineering from malicious external users.

## Assumptions
- **Security:** Developers and CI machines will pass the token to the build script securely via an environment variable (`HF_TOKEN`) instead of hardcoding it in a source file.
- **Performance:** Runtime initialization performance will remain unchanged, but the initial network download is completely eliminated.
- **Maintenance:** Local developers will only incur the 6GB download penalty once. The script caches the model in a local build folder.

## Decision Log
- **Decision:** Bundle the model at build-time using a shell script rather than at run-time or via Git LFS.
  - **Alternatives Considered:** Downloading the model seamlessly at first-run in the background; committing the 6GB model directly to Git LFS.
  - **Reasoning:** Since this is an internal application, a 6GB build footprint is acceptable. Embedding the model entirely removes internet dependencies and token passing at runtime. The CLI is the most robust way to download models with proper resume/caching mechanisms.

## Final Design

### Part 1: Build Script & Xcode Integration
- Create `download_model.sh`.
- Script checks if `./GemmaModel` directory exists. If yes, exit 0.
- Script verifies `HF_TOKEN` environment variable exists. (Exit 1 if missing).
- Execute `huggingface-cli download mlx-community/gemma-4-e4b-it-4bit --local-dir ./GemmaModel --token $HF_TOKEN`.
- Add a "Run Script" build phase positioned natively *before* the "Copy Bundle Resources" phase in Xcode.
- Add `./GemmaModel` to Xcode's "Copy Bundle Resources" targeting.

### Part 2: Application Refactoring
- **UI Modifications (`DashboardView.swift`):** Remove Hugging Face Token input, `KeychainHelper` storage, and the manual "Download & Prepare Model" button. Simplify to just "Initialize Stream".
- **Service Modifications (`NativeVLMClient.swift`):** Remove all `HubApi` network dependencies. Modify `prepareModel()` to locate the local bundle via `Bundle.main.url(forResource: "GemmaModel", withExtension: nil)` and load it directly into Unified Memory via `VLMModelFactory`.
