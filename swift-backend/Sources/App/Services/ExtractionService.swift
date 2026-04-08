import Foundation
import Vapor
import Fluent
import AVFoundation
import UniformTypeIdentifiers

struct ExtractionService: Sendable {
    static func extractAndAnalyze(filename: String, db: Database, logger: Logger, client: Client) async {
        logger.info("Started native AVFoundation extraction for \(filename)")
        let uploadsDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("../backend/uploads/")
        let videoURL = uploadsDir.appendingPathComponent(filename)
        
        guard FileManager.default.fileExists(atPath: videoURL.path) else {
            logger.error("File not found")
            await ExtractionProgress.shared.set(status: "error", current: 0, total: 0, for: filename)
            return
        }
        
        let asset = AVAsset(url: videoURL)
        guard let duration = try? await asset.load(.duration) else {
            await ExtractionProgress.shared.set(status: "error", current: 0, total: 0, for: filename)
            return
        }
        
        let seconds = CMTimeGetSeconds(duration)
        if seconds <= 0 { return }
        
        // --- AUDIO METRICS PASS ---
        // Basic Audio extraction thresholds mapped for native linear PCM (Int16)
        var hasStatic = false
        var hasBuzzing = false
        var hasClicking = false
        var hasSilence = true
        
        if let audioTrack = try? await asset.loadTracks(withMediaType: .audio).first {
            let outputSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
            
            if let assetReader = try? AVAssetReader(asset: asset) {
                let trackOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: outputSettings)
                assetReader.add(trackOutput)
                
                if assetReader.startReading() {
                    var maxAmplitude: Float = 0.0
                    var averageAmplitude: Float = 0.0
                    var readings = 0
                    var zeroCrossings = 0
                    
                    while assetReader.status == .reading {
                        if let sampleBuffer = trackOutput.copyNextSampleBuffer() {
                            if let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) {
                                let length = CMBlockBufferGetDataLength(blockBuffer)
                                var data = [Int16](repeating: 0, count: length / MemoryLayout<Int16>.stride)
                                CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: &data)
                                
                                var lastSample: Int16 = 0
                                for sample in data {
                                    let floatSample = Float(abs(sample))
                                    averageAmplitude += floatSample
                                    if floatSample > maxAmplitude {
                                        maxAmplitude = floatSample
                                    }
                                    if (sample > 0 && lastSample < 0) || (sample < 0 && lastSample > 0) {
                                        zeroCrossings += 1
                                    }
                                    lastSample = sample
                                    readings += 1
                                }
                            }
                        }
                    }
                    if readings > 0 {
                        averageAmplitude /= Float(readings)
                        let zeroCrossRate = Float(zeroCrossings) / Float(readings)
                        
                        let decibels = 20 * log10(averageAmplitude / 32767.0)
                        
                        if decibels > -50.0 { hasSilence = false }
                        
                        // Heuristics
                        if zeroCrossRate > 0.4 { hasStatic = true } 
                        if maxAmplitude > 32000.0 && averageAmplitude > 10000.0 { hasBuzzing = true } 
                        if maxAmplitude > 28000.0 && zeroCrossRate < 0.1 && averageAmplitude < 1000.0 { hasClicking = true } 
                        
                        logger.info("Audio metrics for \(filename) — db: \(decibels), max: \(maxAmplitude), ZCR: \(zeroCrossRate)")
                    }
                }
            }
        }
        
        // Log Audio Issues Once
        var audioIssues: [(String, Double, String)] = []
        if hasStatic { audioIssues.append(("static_audio", 1.0, "avfoundation")) }
        if hasBuzzing { audioIssues.append(("buzzing_audio", 1.0, "avfoundation")) }
        if hasClicking { audioIssues.append(("clicking_audio", 1.0, "avfoundation")) }
        if hasSilence { audioIssues.append(("no_audio", 1.0, "avfoundation")) }
        
        for (issue, score, engine) in audioIssues {
            let log = VideoLog()
            log.videoFilename = filename
            log.timestampSec = 0.0
            log.nodeSource = "Primary-Ingest-A"
            log.nodeBackbone = "East-Backbone-2"
            log.nodeDest = "Distribution-Node"
            log.issueType = issue
            log.issueScore = score
            log.analysisEngine = engine
            try? await log.save(on: db)
        }

        // --- VIDEO EXTRACTION PASS ---
        var anyVideoFramesSaved = false
        let thumbnailsDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("../backend/thumbnails/")
        try? FileManager.default.createDirectory(at: thumbnailsDir, withIntermediateDirectories: true)
        
        let fps = 1.0
        let totalFrames = Int(seconds * fps)
        
        await ExtractionProgress.shared.set(status: "analyzing", current: 0, total: totalFrames, for: filename)
        
        let imageGenerator = AVAssetImageGenerator(asset: asset)
        imageGenerator.requestedTimeToleranceBefore = .zero
        imageGenerator.requestedTimeToleranceAfter = .zero
        imageGenerator.appliesPreferredTrackTransform = true
        
        for i in 0..<totalFrames {
            do {
                let time = CMTime(seconds: Double(i), preferredTimescale: 600)
                let (cgImage, actualTime) = try await imageGenerator.image(at: time)
                let timestamp = CMTimeGetSeconds(actualTime)
                
                let frameName = String(format: "%@_frame_%04d.jpg", filename, i)
                let thumbURL = thumbnailsDir.appendingPathComponent(frameName)
                
                if let dest = CGImageDestinationCreateWithURL(thumbURL as CFURL, UTType.jpeg.identifier as CFString, 1, nil) {
                    CGImageDestinationAddImage(dest, cgImage, nil)
                    CGImageDestinationFinalize(dest)
                }
                
                let cvResults = VisionAnalyzer.analyze(imagePath: thumbURL.path)
                
                var issuesFound: [(String, Double, String)] = []
                var videoIssueFound = false
                
                if let cv = cvResults {
                    if cv.isBlackScreen {
                        issuesFound.append(("black_screen", 1.0, "coreimage"))
                        videoIssueFound = true
                    }
                    if cv.isBlurry {
                        issuesFound.append(("blur", 1.0, "coreimage"))
                        videoIssueFound = true
                    }
                    if cv.blockiness > 1.25 {
                        issuesFound.append(("macroblocking", 1.0, "coreimage"))
                        videoIssueFound = true
                    }
                    if cv.hasTopArtifact {
                        issuesFound.append(("top_artifact", 1.0, "coreimage"))
                        videoIssueFound = true
                    }
                }
                
                // Ai Check
                if !videoIssueFound && i % 5 == 0 {
                    let (isSlate, conf) = await OllamaClient.analyzeFrame(client: client, imagePath: thumbURL.path, model: "moondream")
                    if isSlate {
                        issuesFound.append(("slate", conf, "quick_ai"))
                        videoIssueFound = true
                    } else {
                        let (fallbackSlate, fallbackConf) = await OllamaClient.analyzeFrame(client: client, imagePath: thumbURL.path, model: "llava")
                        if fallbackSlate {
                            issuesFound.append(("slate", fallbackConf, "heavy_ai"))
                        }
                    }
                }
                
                for (issue, score, engine) in issuesFound {
                    let log = VideoLog()
                    log.videoFilename = filename
                    log.timestampSec = timestamp
                    log.nodeSource = "Primary-Ingest-A"
                    log.nodeBackbone = "East-Backbone-2"
                    log.nodeDest = "Distribution-Node"
                    log.issueType = issue
                    log.issueScore = score
                    log.analysisEngine = engine
                    log.thumbnailPath = frameName
                    
                    try? await log.save(on: db)
                }
                anyVideoFramesSaved = true
                
            } catch {
                logger.error("Failed to extract frame \(i): \(error)")
            }
            await ExtractionProgress.shared.set(status: "analyzing", current: i + 1, total: totalFrames, for: filename)
        }
        
        if !anyVideoFramesSaved && audioIssues.isEmpty {
            let log = VideoLog()
            log.videoFilename = filename
            log.timestampSec = 0.0
            log.nodeSource = "Primary-Ingest-A"
            log.nodeBackbone = "East-Backbone-2"
            log.nodeDest = "Distribution-Node"
            log.issueType = "ok"
            log.issueScore = 1.0
            log.analysisEngine = "avfoundation"
            try? await log.save(on: db)
        }
        
        await ExtractionProgress.shared.set(status: "completed", current: totalFrames, total: totalFrames, for: filename)
        logger.info("Extraction completed for \(filename)")
    }
}
