import Foundation
import AppKit
import UniformTypeIdentifiers
import CoreText

enum ExportFormat {
    case csv, json, pdf
}

struct VideoLogDTO: Codable {
    let videoFilename: String
    let timestampSec: Double
    let nodeSource: String?
    let nodeBackbone: String?
    let nodeDest: String?
    let issueType: String
    let issueScore: Double?
    let analysisEngine: String?
    let createdAt: Date
    let sessionIdentifier: String?
    let sessionStartTime: Date?
    let issueSummary: String?
    let iatMs: Double?
}

@MainActor
class DatabaseExporter {
    static func export(logs: [VideoLog], format: ExportFormat, window: NSWindow?) {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        let timeStr = Int(Date().timeIntervalSince1970)
        panel.nameFieldStringValue = "LogExport_\(timeStr)"
        
        switch format {
        case .csv:
            if #available(macOS 11.0, *) {
                panel.allowedContentTypes = [.commaSeparatedText]
            } else {
                panel.allowedFileTypes = ["csv"]
            }
            panel.nameFieldStringValue += ".csv"
        case .json:
            if #available(macOS 11.0, *) {
                panel.allowedContentTypes = [.json]
            } else {
                panel.allowedFileTypes = ["json"]
            }
            panel.nameFieldStringValue += ".json"
        case .pdf:
            if #available(macOS 11.0, *) {
                panel.allowedContentTypes = [.pdf]
            } else {
                panel.allowedFileTypes = ["pdf"]
            }
            panel.nameFieldStringValue += ".pdf"
        }
        
        panel.beginSheetModal(for: window ?? NSApp.keyWindow ?? NSWindow()) { response in
            if response == .OK, let url = panel.url {
                Task.detached {
                    do {
                        switch format {
                        case .csv:
                            let data = try await generateCSV(logs: logs)
                            try data.write(to: url, atomically: true, encoding: .utf8)
                        case .json:
                            let data = try await generateJSON(logs: logs)
                            try data.write(to: url)
                        case .pdf:
                            let data = try await generatePDF(logs: logs)
                            try data.write(to: url)
                        }
                    } catch {
                        appLogger.error("Error generating export: \(error.localizedDescription, privacy: .public)")
                    }
                }
            }
        }
    }
    
    static func generateJSON(logs: [VideoLog]) async throws -> Data {
        let dtos = logs.map { log in
            VideoLogDTO(
                videoFilename: log.videoFilename,
                timestampSec: log.timestampSec,
                nodeSource: log.nodeSource,
                nodeBackbone: log.nodeBackbone,
                nodeDest: log.nodeDest,
                issueType: log.issueType,
                issueScore: log.issueScore,
                analysisEngine: log.analysisEngine,
                createdAt: log.createdAt,
                sessionIdentifier: log.sessionIdentifier,
                sessionStartTime: log.sessionStartTime,
                issueSummary: log.issueSummary,
                iatMs: log.iatMs
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(dtos)
    }
    
    static func generateCSV(logs: [VideoLog]) async throws -> String {
        var csv = "Time,Type,Engine,PTS,Confidence,URI,Session\n"
        for log in logs {
            let timeStr = log.createdAt.formatted(date: .omitted, time: .standard)
            let typeStr = log.issueType.replacingOccurrences(of: ",", with: " ")
            let engineStr = (log.analysisEngine ?? "N/A").replacingOccurrences(of: ",", with: " ")
            let ptsStr = String(format: "%.3f", log.timestampSec)
            let confStr = log.issueScore != nil ? String(format: "%.2f", log.issueScore!) : "N/A"
            let uriStr = log.videoFilename.replacingOccurrences(of: ",", with: " ")
            let sessionStr = (log.sessionIdentifier ?? "Unknown").replacingOccurrences(of: ",", with: " ")
            
            csv += "\(timeStr),\(typeStr),\(engineStr),\(ptsStr),\(confStr),\(uriStr),\(sessionStr)\n"
        }
        return csv
    }
    
    static func generatePDF(logs: [VideoLog]) async throws -> Data {
        return await MainActor.run {
            let bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
            let data = NSMutableData()
            guard let consumer = CGDataConsumer(data: data),
                  let context = CGContext(consumer: consumer, mediaBox: nil, nil) else {
                return Data()
            }
            
            var text = "Eyes-on-Glass Event Log Export\n\n"
            text += "Time\tType\tEngine\tPTS\tConfidence\tURI\n"
            for log in logs {
                let timeStr = log.createdAt.formatted(date: .omitted, time: .standard)
                let typeStr = log.issueType.uppercased()
                let engineStr = log.analysisEngine ?? "N/A"
                let ptsStr = String(format: "%.3f", log.timestampSec)
                let confStr = log.issueScore != nil ? String(format: "%.2f", log.issueScore!) : "N/A"
                text += "\(timeStr)\t\(typeStr)\t\(engineStr)\t\(ptsStr)\t\(confStr)\t\(log.videoFilename)\n"
            }
            
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.tabStops = [
                NSTextTab(textAlignment: .left, location: 80, options: [:]),
                NSTextTab(textAlignment: .left, location: 160, options: [:]),
                NSTextTab(textAlignment: .left, location: 260, options: [:]),
                NSTextTab(textAlignment: .left, location: 320, options: [:]),
                NSTextTab(textAlignment: .left, location: 400, options: [:])
            ]
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
                .paragraphStyle: paragraphStyle,
                .foregroundColor: NSColor.black
            ]
            let attrString = NSAttributedString(string: text, attributes: attrs)
            
            let framesetter = CTFramesetterCreateWithAttributedString(attrString)
            var currentRange = CFRange(location: 0, length: 0)
            
            while currentRange.location < attrString.length {
                context.beginPage(mediaBox: nil)
                
                // Flip coordinate system for AppKit/CoreText
                context.textMatrix = .identity
                context.translateBy(x: 0, y: bounds.height)
                context.scaleBy(x: 1.0, y: -1.0)
                
                let path = CGPath(rect: bounds.insetBy(dx: 30, dy: 30), transform: nil)
                let frame = CTFramesetterCreateFrame(framesetter, currentRange, path, nil)
                
                CTFrameDraw(frame, context)
                let visibleRange = CTFrameGetVisibleStringRange(frame)
                currentRange.location += visibleRange.length
                
                context.endPage()
                
                if visibleRange.length == 0 {
                    break // Prevent infinite loop on tight constraints
                }
            }
            
            context.closePDF()
            return data as Data
        }
    }
}
