# Decision Record: Gemma Model Git Strategy

## Understanding Summary
- **What is the problem:** Git Add operations failed abruptly because the automated 4.9GB Gemma model downloads introduced a `.gitattributes` file demanding `git-lfs`, which was not installed locally.
- **Why it exists:** The model and python dependencies are downloaded locally to package the app, but were never formally ignored from the repository tree.
- **Who it is for:** Developers compiling and committing on `Eyes-on-Glass`.
- **Key Constraints:** Standard GitHub rejects commits larger than 100MB. LFS would incur significant extra bandwidth/storage costs for 4.9GB payloads.
- **Explicit Non-Goals:** Do not track the massive offline ML model weights in Git, as we utilize `download_model.sh` to fetch them on-demand or during CI/CD.

## Assumptions
- The `download_model.sh` script is the single authoritative mechanism for acquiring the Gemma weights. 
- Discarding the model from Git history introduces no regressions, provided the script logic remains intact.

## Decision Log

**Decision: Ignore the Local ML Assets**
- **What was decided:** We will append patterns to `.gitignore` to completely exclude the downloaded models and any Python environments.
- **Alternatives considered:** Installing `git-lfs` and purchasing a GitHub data pack to track the native models in repo. 
- **Why this option was chosen:** Tracking heavily-sized binary inferences that are accessible from HuggingFace is an anti-pattern. Excluding them avoids GitHub upload rejections, preserves standard IDE Git GUI flows, and circumvents the need to manage LFS licenses.

## Required Implementation
When executed, the following must be appended to the top-level `.gitignore`:
```text
# Local Virtual Environments
mac-frontend/.hf_venv/

# Large ML Weights / Generated Assets
mac-frontend/Sources/EyesOnGlass/GemmaModel/
```
