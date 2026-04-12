# MLX Native Crash Fix - Decision Log & Final Design

## Understanding Summary

*   **What is being fixed**: Native App crashes via `Failed to load the default metallib` when leveraging MLX on macOS.
*   **Why it exists**: Apple's `mlx-swift` repository (version `0.30+`) abandoned standard SPM package binding for Metal hardware kernels, relying solely on an offline `xcodebuild` step.
*   **Who it is for**: Developers utilizing the native UI and the headless battery testing framework.
*   **Key constraints**: Preserving `package_app.sh` integrity and CLI compilation environments without introducing rigid Xcode schemas globally.
*   **Explicit non-goals**: No additional frontend optimization (e.g., specific loading patterns for larger multi-parameter models).

## Assumptions

*   `EyesOnGlass.app` packaging dynamically hooks into our metadata extraction loop to pull the complete `mlx-swift_Cmlx.bundle` rather than isolated binary fragments.

## Decision Log

### Issue Diagnosed
SwiftPM testing scripts (`swift test`) and native execution via `package_app.sh` were inherently incompatible with newer MLX C++ loading schemas that require full enveloping macOS bundles for shader compilation (`default.metallib`).

### Alternatives Considered
1.   **Migrating the entire build ecosystem to Xcode (Rejected)**: Migrating away from `swift build` to raw `xcodebuild -workspace` would negatively fragment headless workflows and the streamlined deployment of the CLI.
2.   **Manual file-linking the `.metallib` (Rejected)**: This initial approach failed on the visual application instance because `try_load_bundle` strictly looks for an `NSBundle` struct mapping to the identifier `"mlx-swift_Cmlx"`.
3.   **Injection of the entire `.bundle` via an intermediary script (Chosen)**: We built a proxy script (`build_metal_shaders.sh`) that hooks purely into the shader schema and clones the *entire* `.bundle` structure mapping identically to `EyesOnGlass.app/Contents/Resources`.

### Final Design
The final design implements a transparent extraction strategy within `package_app.sh`:

```bash
# We must copy the ENTIRE .bundle structure because mlx looks for 'mlx-swift_Cmlx.bundle' 
# when running natively as an App
if [[ -d "$ROOT/.build/xcodebuild/Debug/mlx-swift_Cmlx.bundle" ]]; then
  cp -R "$ROOT/.build/xcodebuild/Debug/mlx-swift_Cmlx.bundle" "$APP/Contents/Resources/"
elif [[ -d "$ROOT/.build/xcodebuild/Release/mlx-swift_Cmlx.bundle" ]]; then
  cp -R "$ROOT/.build/xcodebuild/Release/mlx-swift_Cmlx.bundle" "$APP/Contents/Resources/"
fi
```
This enables zero-friction, hardware-accelerated Gemma 4 processing globally inside and outside Xcode.
