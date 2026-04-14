import os
import glob

test_dir = "mac-frontend/Tests/EyesOnGlassTests"
files = glob.glob(f"{test_dir}/*.swift")

for file in files:
    with open(file, "r") as f:
        text = f.read()
    
    original = text
    
    # In tests, we can just instantiate a StreamController
    if "StreamController.shared" in text or "UIVisualsRenderer.shared" in text or "LiveStreamService.shared" in text:
        # Before we do blanket replacements, let's inject a controller if needed
        # We'll just replace 'StreamController.shared' with a generic 'controller'
        # But wait, each test function might need 'let controller = await MainActor.run { StreamController() }'
        
        # A simpler way for UIVisualsRendererTests:
        if "UIVisualsRendererTests" in file:
            text = text.replace("StreamController.shared", "controller")
            text = text.replace("UIVisualsRenderer.shared", "renderer")
            text = text.replace("func testUIVisualsRendererPassesDataToStreamController() async throws {", "func testUIVisualsRendererPassesDataToStreamController() async throws {\n        let controller = await MainActor.run { StreamController() }\n        let renderer = UIVisualsRenderer(streamController: controller)\n")
            
        elif "LiveStreamServiceTelemetryTests" in file:
            text = text.replace("LiveStreamService.shared", "LiveStreamService(streamController: nil)")
            
        elif "LiveStreamServiceTests" in file:
            text = text.replace("LiveStreamService.shared", "LiveStreamService(streamController: nil)")
            text = text.replace("UIVisualsRenderer.shared.", "UIVisualsRenderer(streamController: nil).")
            
    if text != original:
        with open(file, "w") as f:
            f.write(text)
        print(f"Updated {file}")

print("Test patching done!")
