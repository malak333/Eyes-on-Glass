import Foundation
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
process.arguments = ["-S", "powermetrics", "--samplers", "gpu_power", "-n", "1", "-i", "10"]
let pipe = Pipe()
process.standardOutput = pipe
process.standardError = pipe
do {
    try process.run()
    process.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    print(String(data: data, encoding: .utf8) ?? "")
} catch {
    print("Error: \(error)")
}
