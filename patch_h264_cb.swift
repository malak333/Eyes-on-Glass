import Foundation

let path = "/Users/michaelnobile/Antigravity/Eyes-on-Glass/mac-frontend/Sources/EyesOnGlass/Services/H264Decoder.swift"
var content = try! String(contentsOfFile: path)

let fpsLogic = """
        guard status == noErr, let pixelBuffer = imageBuffer else { return }
        let pts = presentationTimeStamp.value
        
        if let lastPTS = decoder.lastEmittedPTS {
            let delta = Double(pts - lastPTS) / 90000.0
            if delta > 0 && delta < 1.0 {
                let instFps = 1.0 / delta
                if decoder.currentFrameRate == 0 { decoder.currentFrameRate = instFps }
                else { decoder.currentFrameRate = (decoder.currentFrameRate * 0.9) + (instFps * 0.1) }
            }
        }
        decoder.lastEmittedPTS = pts
        
        // print("H264Decoder: VT Callback emitted frame (PTS: \\(pts))")
"""

content = content.replacingOccurrences(of: """
        guard status == noErr, let pixelBuffer = imageBuffer else { return }
        let pts = presentationTimeStamp.value
        print("H264Decoder: VT Callback emitted frame (PTS: \\(pts))")
""", with: fpsLogic)

try! content.write(toFile: path, atomically: true, encoding: .utf8)
