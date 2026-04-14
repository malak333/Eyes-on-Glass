import os

file = "mac-frontend/Tests/EyesOnGlassTests/UIVisualsRendererTests.swift"
with open(file, "r") as f:
    text = f.read()

text = text.replace("let renderer = renderer\n", "let renderer = UIVisualsRenderer(streamController: controller)\n")

with open(file, "w") as f:
    f.write(text)
print("Fixed renderer loop!")
