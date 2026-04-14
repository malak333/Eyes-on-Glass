import re

# Fix StreamController
with open("mac-frontend/Sources/EyesOnGlass/Controllers/StreamController.swift", "r") as f:
    text = f.read()

text = text.replace("static func == (lhs: StreamController, rhs: StreamController) -> Bool {", "nonisolated static func == (lhs: StreamController, rhs: StreamController) -> Bool {")
text = text.replace("func hash(into hasher: inout Hasher) {", "nonisolated func hash(into hasher: inout Hasher) {")

with open("mac-frontend/Sources/EyesOnGlass/Controllers/StreamController.swift", "w") as f:
    f.write(text)

# Fix CLI
with open("mac-frontend/Sources/EyesOnGlass/CLI.swift", "r") as f:
    text = f.read()

text = text.replace("var videoFiles = [", "let videoFiles = [")

with open("mac-frontend/Sources/EyesOnGlass/CLI.swift", "w") as f:
    f.write(text)

print("Warnings fixed!")
