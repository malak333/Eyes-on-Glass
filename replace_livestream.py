import re

with open("mac-frontend/Sources/EyesOnGlass/Services/LiveStreamService.swift", "r") as f:
    text = f.read()

# Replace UIVisualsRenderer singleton
text = re.sub(
    r"class UIVisualsRenderer: @unchecked Sendable \{\n    static let shared = UIVisualsRenderer\(\)\n",
    r"class UIVisualsRenderer: @unchecked Sendable {\n    private weak var streamController: StreamController?\n\n    init(streamController: StreamController?) {\n        self.streamController = streamController\n    }\n\n",
    text
)

text = text.replace("StreamController.shared.isAdvancedInspectorVisible", "self.streamController?.isAdvancedInspectorVisible == true")
text = text.replace("StreamController.shared.currentFrameImage", "self.streamController?.currentFrameImage")
text = text.replace("StreamController.shared.audioWaveformData", "self.streamController?.audioWaveformData")
text = text.replace("StreamController.shared.audioVectorscopeData", "self.streamController?.audioVectorscopeData")
text = text.replace("StreamController.shared.audioPhaseData", "self.streamController?.audioPhaseData")
text = text.replace("StreamController.shared.audioLevelsData", "self.streamController?.audioLevelsData")

# Replace LiveStreamService singleton
text = re.sub(
    r"actor LiveStreamService \{\n    static let shared = LiveStreamService\(\)\n",
    r"actor LiveStreamService {\n    private weak var streamController: StreamController?\n    private let visualsRenderer: UIVisualsRenderer\n\n    init(streamController: StreamController?) {\n        self.streamController = streamController\n        self.visualsRenderer = UIVisualsRenderer(streamController: streamController)\n    }\n",
    text
)

text = text.replace("UIVisualsRenderer.shared.", "self.visualsRenderer.")
text = text.replace("StreamController.shared.", "self.streamController?.")

with open("mac-frontend/Sources/EyesOnGlass/Services/LiveStreamService.swift", "w") as f:
    f.write(text)

print("Updated LiveStreamService.swift!")
