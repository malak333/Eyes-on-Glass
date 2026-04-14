import re

with open("mac-frontend/Sources/EyesOnGlass/Views/DashboardView.swift", "r") as f:
    text = f.read()

# Add computed property
prop_to_add = """    var activeLogs: [VideoLog] {
        if let id = streamController.currentSessionIdentifier {
            return logs.filter { $0.sessionIdentifier == id }
        } else {
            return []
        }
    }
"""
text = text.replace("    @State private var showAdvancedInspector: Bool = false\n", "    @State private var showAdvancedInspector: Bool = false\n" + prop_to_add)

# Replace passing logs to views
text = text.replace("DashboardSidebar(streamController: streamController, modelContext: modelContext, logs: logs)", "DashboardSidebar(streamController: streamController, modelContext: modelContext, logs: activeLogs)")

text = text.replace("if logs.isEmpty {", "if activeLogs.isEmpty {")
text = text.replace("ForEach(logs) { log in", "ForEach(activeLogs) { log in")

with open("mac-frontend/Sources/EyesOnGlass/Views/DashboardView.swift", "w") as f:
    f.write(text)

print("Updated DashboardView.swift!")
