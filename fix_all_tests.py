import glob

files = glob.glob("mac-frontend/Tests/EyesOnGlassTests/*.swift")

for file in files:
    with open(file, 'r') as f:
        text = f.read()

    original = text

    # Global fixes for StreamController.shared
    # For BatteryIntegrationTests, AudioDecoderTests, etc.
    text = text.replace("StreamController.shared", "StreamController()")
    text = text.replace("LiveStreamService.shared", "LiveStreamService(streamController: nil)")
    text = text.replace("UIVisualsRenderer.shared.", "UIVisualsRenderer(streamController: nil).")

    # In UIVisualsRendererTests, we modified 'StreamController.shared' to 'controller'
    # Let's fix that by adding a class member `var controller: StreamController!` and initializing it
    if "UIVisualsRendererTests" in file:
        if "var controller:" not in text:
            # We must run this in setUp method, but we can also just initialize it inline
            text = text.replace("final class UIVisualsRendererTests: XCTestCase {\n", 
                                "final class UIVisualsRendererTests: XCTestCase {\n    var controller = StreamController()\n")
            text = text.replace("let controller = await MainActor.run { StreamController() }", "")
    
    # BatteryIntegrationTests - extractAndAnalyze signature
    if "BatteryIntegrationTests" in file:
        text = text.replace("await ExtractionService.extractAndAnalyze(filename: filename)", "await ExtractionService.extractAndAnalyze(filename: filename, streamController: StreamController())")

    with open(file, 'w') as f:
        f.write(text)

print("Test patches applied.")
