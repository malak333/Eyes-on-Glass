import re

with open("mac-frontend/Sources/EyesOnGlass/Controllers/StreamController.swift", "r") as f:
    text = f.read()

# Replace StreamController singleton
text = re.sub(
    r"final class StreamController \{\n    static let shared = StreamController\(\)\n",
    r"final class StreamController: Identifiable, Hashable {\n    let id = UUID()\n    private(set) var liveStreamService: LiveStreamService!\n\n    static func == (lhs: StreamController, rhs: StreamController) -> Bool {\n        lhs.id == rhs.id\n    }\n\n    func hash(into hasher: inout Hasher) {\n        hasher.combine(id)\n    }\n",
    text
)

# Init modification to inject liveStreamService
# I need to find the `init() {` block.
init_idx = text.find("\n    init() {\n")
if init_idx != -1:
    text = text[:init_idx] + "\n    init() {\n        self.liveStreamService = LiveStreamService(streamController: self)\n" + text[init_idx + 13:]

text = text.replace("LiveStreamService.shared.", "self.liveStreamService.")

with open("mac-frontend/Sources/EyesOnGlass/Controllers/StreamController.swift", "w") as f:
    f.write(text)

print("Updated StreamController.swift!")
