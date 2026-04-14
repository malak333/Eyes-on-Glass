import re

with open("mac-frontend/Sources/EyesOnGlass/Services/ExtractionService.swift", "r") as f:
    text = f.read()

text = text.replace("static func extractAndAnalyze(filename: String, ) async {", "static func extractAndAnalyze(filename: String, streamController: StreamController) async {")
text = text.replace("static func extractAndAnalyze(filename: String) async {", "static func extractAndAnalyze(filename: String, streamController: StreamController) async {")

text = text.replace("await StreamController.shared.insertVideoLog", "await streamController.insertVideoLog")

with open("mac-frontend/Sources/EyesOnGlass/Services/ExtractionService.swift", "w") as f:
    f.write(text)

print("Updated ExtractionService.swift!")
