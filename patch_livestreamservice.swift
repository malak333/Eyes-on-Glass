import Foundation

let path = "./swift-backend/Sources/App/Services/LiveStreamService.swift"
var content = try! String(contentsOfFile: path)

let target = """
            let now = Date().timeIntervalSince1970
            if issuesFound.isEmpty {
                if now - lastOkLogTime >= 60 || lastOkLogTime == 0 {
                    let log = VideoLog()
                    log.videoFilename = sessionName
                    log.timestampSec = Double(currentFrameIndex)
                    log.nodeSource = "Live-Multicast"
                    log.nodeBackbone = "East-Backbone-Live"
                    log.nodeDest = "Distribution-Node"
                    log.issueType = "ok"
                    log.issueScore = 1.0
                    log.analysisEngine = "avfoundation"
                    try? await log.save(on: db)
                    lastOkLogTime = now
                }
                
                try? FileManager.default.removeItem(at: thumbURL)
"""

let replacement = """
            let now = Date().timeIntervalSince1970
            if issuesFound.isEmpty {
                let log = VideoLog()
                log.videoFilename = sessionName
                log.timestampSec = Double(currentFrameIndex)
                log.nodeSource = "Live-Multicast"
                log.nodeBackbone = "East-Backbone-Live"
                log.nodeDest = "Distribution-Node"
                log.issueType = "ok"
                log.issueScore = 1.0
                log.analysisEngine = "avfoundation"
                try? await log.save(on: db)
                lastOkLogTime = now
                
                try? FileManager.default.removeItem(at: thumbURL)
"""

content = content.replacingOccurrences(of: target, with: replacement)
try! content.write(toFile: path, atomically: true, encoding: .utf8)
print("Patched.")
