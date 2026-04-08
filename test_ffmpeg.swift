import Foundation
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
p.arguments = ["ffmpeg", "-y", "-nostdin", "-v", "error", "-i", "/Users/michaelnobile/Antigravity/Eyes-on-Glass/uploads/KGO-VOD-Encoder.ts", "-vf", "fps=1.0", "-qscale:v", "2", "/Users/michaelnobile/Antigravity/Eyes-on-Glass/backend/thumbnails/KGO_TEST_%04d.jpg"]
try! p.run()
p.waitUntilExit()
print("Exit: \(p.terminationStatus)")
