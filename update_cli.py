import re

with open("mac-frontend/Sources/EyesOnGlass/CLI.swift", "r") as f:
    text = f.read()

# Replace StreamController.shared usages
text = text.replace("StreamController.shared.modelContext = container.mainContext", "")
text = text.replace("await MainActor.run {\n        \n    }", "")

# Create StreamController and assign modelContext above the execution loop
text = text.replace("let executionTiers: [GemmaModelTier] = [.e4b]", 
"""let executionTiers: [GemmaModelTier] = [.e4b]
        
        let offlineStreamController = await MainActor.run { 
            let ctrl = StreamController()
            ctrl.modelContext = container.mainContext
            return ctrl
        }""")

# Pass streamController to ExtractionService
text = text.replace("await ExtractionService.extractAndAnalyze(filename: filename)", "await ExtractionService.extractAndAnalyze(filename: filename, streamController: offlineStreamController)")

with open("mac-frontend/Sources/EyesOnGlass/CLI.swift", "w") as f:
    f.write(text)

print("Updated CLI.swift!")
