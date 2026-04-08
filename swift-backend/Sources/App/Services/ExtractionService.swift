import Foundation
import Vapor
import Fluent
import AVFoundation
import UniformTypeIdentifiers
import Accelerate

struct ExtractionService: Sendable {
    static func detectFreeze(videoPath: String) async -> [(Double, Double)] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "ffmpeg", "-nostdin", "-i", videoPath,
            "-an",
            "-vf", "freezedetect=n=-60dB:d=2.0",
            "-f", "null", "-"
        ]
        let pipe = Pipe()
        process.standardError = pipe
        
        do {
            try process.run()
        } catch { 
            return [] 
        }
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        
        guard let output = String(data: data, encoding: .utf8) else { return [] }
        
        var intervals: [(Double, Double)] = []
        var currentStart: Double? = nil
        
        let startRegex = try? NSRegularExpression(pattern: "lavfi\\.freezedetect\\.freeze_start:\\s*([\\d\\.]+)")
        let endRegex = try? NSRegularExpression(pattern: "lavfi\\.freezedetect\\.freeze_end:\\s*([\\d\\.]+)")
        
        let lines = output.components(separatedBy: .newlines)
        for line in lines {
            let nsRange = NSRange(line.startIndex..<line.endIndex, in: line)
            if let startMatch = startRegex?.firstMatch(in: line, range: nsRange), startMatch.numberOfRanges > 1 {
                if let r = Range(startMatch.range(at: 1), in: line), let val = Double(line[r]) {
                    currentStart = val
                }
            }
            if let endMatch = endRegex?.firstMatch(in: line, range: nsRange), endMatch.numberOfRanges > 1 {
                if let r = Range(endMatch.range(at: 1), in: line), let val = Double(line[r]), let start = currentStart {
                    intervals.append((start, val))
                    currentStart = nil
                }
            }
        }
        if let start = currentStart {
            intervals.append((start, .infinity))
        }
        return intervals
    }

    static func analyzeAudio(asset: AVAsset, videoURL: URL, useFFmpegFallback: Bool, filename: String, logger: Logging.Logger) async -> ([(Double, Double)], Bool, Bool, Bool, Bool) {
        var hasLipSync = false
        var hasStatic = false
        var hasBuzzing = false
        var hasClicking = false
        var silenceIntervals: [(Double, Double)] = [(0.0, .infinity)]

        if let vTrack = try? await asset.loadTracks(withMediaType: .video).first,
           let aTrack = try? await asset.loadTracks(withMediaType: .audio).first {
            if let vTime = try? await vTrack.load(.timeRange),
               let aTime = try? await aTrack.load(.timeRange) {
                let vStart = CMTimeGetSeconds(vTime.start)
                let aStart = CMTimeGetSeconds(aTime.start)
                if !vStart.isNaN && !aStart.isNaN {
                    let offset = abs(vStart - aStart)
                    if offset > 0.25 {
                        logger.info("Container PTS offset detected for \(filename): \(offset)s")
                        hasLipSync = true
                    }
                }
            }
        }

        if useFFmpegFallback && !hasLipSync {
            let ptsProcess = Process()
            ptsProcess.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            ptsProcess.arguments = [
                "ffprobe", "-v", "error",
                "-show_entries", "stream=codec_type,start_time",
                "-of", "json",
                videoURL.path
            ]
            let pipe = Pipe()
            ptsProcess.standardOutput = pipe
            try? ptsProcess.run()
            if let data = try? pipe.fileHandleForReading.readToEnd() {
                ptsProcess.waitUntilExit()
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let streams = json["streams"] as? [[String: Any]] {
                    var vStart: Double? = nil
                    var aStart: Double? = nil
                    for s in streams {
                        if s["codec_type"] as? String == "video" && vStart == nil {
                            if let st = s["start_time"] as? String, let val = Double(st) { vStart = val }
                            else if let st = s["start_time"] as? NSNumber { vStart = st.doubleValue }
                        } else if s["codec_type"] as? String == "audio" && aStart == nil {
                            if let st = s["start_time"] as? String, let val = Double(st) { aStart = val }
                            else if let st = s["start_time"] as? NSNumber { aStart = st.doubleValue }
                        }
                    }
                    if let v = vStart, let a = aStart {
                        let offset = abs(v - a)
                        if offset > 0.25 {
                            logger.info("Container PTS offset detected via ffprobe for \(filename): \(offset)s")
                            hasLipSync = true
                        }
                    }
                }
            }
        }

        if let audioTrack = try? await asset.loadTracks(withMediaType: .audio).first {
            let outputSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
                AVNumberOfChannelsKey: 1,
                AVSampleRateKey: 44100
            ]
            
            if let assetReader = try? AVAssetReader(asset: asset) {
                let trackOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: outputSettings)
                if assetReader.canAdd(trackOutput) {
                    assetReader.add(trackOutput)
                    if assetReader.startReading() {
                        var maxAmplitude: Float = 0.0
                        var averageAmplitude: Float = 0.0
                        var readings = 0
                        var zeroCrossings: Double = 0
                        
                        silenceIntervals = []
                        var inSilence = false
                        var currentSilenceStart: Double = 0.0
                        var chunkIndex = 0
                        
                        let windowSize = 22050
                        var chunkReadings = 0
                        var chunkAverage: Float = 0.0
                        
                        var allDiffs: [Float] = []
                        var allSamplesCount = 0
                        
                        while assetReader.status == .reading {
                            if let sampleBuffer = trackOutput.copyNextSampleBuffer() {
                                if let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) {
                                    let length = CMBlockBufferGetDataLength(blockBuffer)
                                    let count = length / MemoryLayout<Int16>.stride
                                    let safeLength = count * MemoryLayout<Int16>.stride
                                    
                                    if safeLength > 0 {
                                        var data = [Int16](repeating: 0, count: count)
                                        data.withUnsafeMutableBytes { bufferPtr in
                                            if let baseAddress = bufferPtr.baseAddress {
                                                CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: safeLength, destination: baseAddress)
                                            }
                                        }
                                        
                                        var floatData = [Float](repeating: 0, count: count)
                                        vDSP_vflt16(data, 1, &floatData, 1, vDSP_Length(count))
                                        
                                        var localMax: Float = 0
                                        var localMin: Float = 0
                                        vDSP_maxv(floatData, 1, &localMax, vDSP_Length(count))
                                        vDSP_minv(floatData, 1, &localMin, vDSP_Length(count))
                                        let loopMax = max(abs(localMax), abs(localMin))
                                        if loopMax > maxAmplitude { maxAmplitude = loopMax }
                                        
                                        var floatAbs = [Float](repeating: 0, count: count)
                                        vDSP_vabs(floatData, 1, &floatAbs, 1, vDSP_Length(count))
                                        
                                        var localSum: Float = 0
                                        vDSP_sve(floatAbs, 1, &localSum, vDSP_Length(count))
                                        averageAmplitude += localSum
                                        
                                        let preCount = readings
                                        readings += count
                                        allSamplesCount += count
                                        
                                        var lastSign: Float = 0
                                        for i in 0..<count {
                                            let sample = data[i]
                                            let currentSign: Float = sample > 0 ? 1 : (sample < 0 ? -1 : 0)
                                            if i > 0 || preCount > 0 {
                                                let diff = abs(currentSign - lastSign)
                                                zeroCrossings += Double(diff) / 2.0
                                            }
                                            lastSign = currentSign
                                            
                                            // Append diffs for click logic
                                            if preCount > 0 || i > 0 {
                                                if i > 0 {
                                                    allDiffs.append(abs(floatData[i] - floatData[i-1]))
                                                }
                                            }
                                        }
                                        
                                        chunkReadings += count
                                        chunkAverage += localSum
                                        
                                        while chunkReadings >= windowSize {
                                            let chunkAvg = chunkAverage / Float(chunkReadings)
                                            let chunkDecibels = 20 * log10(max(1, chunkAvg) / 32767.0)
                                            let startTime = Double(chunkIndex * windowSize) / 44100.0
                                            
                                            if chunkDecibels < -30.0 {
                                                if !inSilence {
                                                    inSilence = true
                                                    currentSilenceStart = startTime
                                                }
                                            } else {
                                                if inSilence {
                                                    inSilence = false
                                                    silenceIntervals.append((currentSilenceStart, startTime))
                                                }
                                            }
                                            
                                            chunkAverage = 0.0
                                            chunkReadings = 0
                                            chunkIndex += 1
                                        }
                                    }
                                }
                            }
                        }
                        if readings > 0 {
                            averageAmplitude /= Float(readings)
                            let zeroCrossRate = Float(zeroCrossings) / Float(readings)
                            
                            let decibels = 20 * log10(max(1, averageAmplitude) / 32767.0)
                            
                            if inSilence {
                                silenceIntervals.append((currentSilenceStart, .infinity))
                            }
                            
                            var clickCount = 0
                            var maxDiff: Float = 0
                            if allDiffs.count > 0 {
                                var sumDiff: Float = 0
                                vDSP_sve(allDiffs, 1, &sumDiff, vDSP_Length(allDiffs.count))
                                let meanDiff = sumDiff / Float(allDiffs.count)
                                
                                var meanSubtracted = [Float](repeating: -meanDiff, count: allDiffs.count)
                                vDSP_vadd(allDiffs, 1, meanSubtracted, 1, &meanSubtracted, 1, vDSP_Length(allDiffs.count))
                                
                                var sqDiffs = [Float](repeating: 0, count: allDiffs.count)
                                vDSP_vsq(meanSubtracted, 1, &sqDiffs, 1, vDSP_Length(allDiffs.count))
                                
                                var varianceSum: Float = 0
                                vDSP_sve(sqDiffs, 1, &varianceSum, vDSP_Length(allDiffs.count))
                                let stdDiff = sqrt(varianceSum / Float(allDiffs.count))
                                
                                let threshold = meanDiff + 20 * stdDiff
                                
                                for d in allDiffs {
                                    if d > maxDiff { maxDiff = d }
                                    if d > threshold { clickCount += 1 }
                                }
                                
                                if clickCount > 10 && maxDiff > 2000 && (maxDiff / (meanDiff + 1e-5)) > 100 {
                                    hasClicking = true
                                }
                            }
                            
                            if zeroCrossRate > 0.20 { hasStatic = true } 
                            if maxAmplitude > 30000.0 && averageAmplitude > 10000.0 && zeroCrossRate < 0.20 { hasBuzzing = true } 
                            
                            logger.info("Audio metrics for \(filename) — db: \(decibels), max: \(maxAmplitude), ZCR: \(zeroCrossRate), Clicks: \(clickCount)")
                        }
                    }
                } else {
                    logger.warning("AVAssetReader could not add track output for \(filename)")
                }
            }
        }
        return (silenceIntervals, hasStatic, hasBuzzing, hasClicking, hasLipSync)
    }

    static func extractFrames(asset: AVAsset, videoURL: URL, useFFmpegFallback: Bool, seconds: Double, fps: Double, filename: String, thumbnailsDir: URL, logger: Logging.Logger) async -> [(path: String, timestamp: Double)] {
        var framesToAnalyze: [(path: String, timestamp: Double)] = []
        
        if useFFmpegFallback {
            logger.warning("Deciding to use FFmpeg fallback for \(filename)")
            let ffmpeg = Process()
            ffmpeg.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            let pattern = thumbnailsDir.appendingPathComponent("\(filename)_frame_%04d.jpg").path
            ffmpeg.arguments = [
                "ffmpeg", "-y", "-nostdin", "-v", "error",
                "-i", videoURL.path,
                "-vsync", "0",
                "-vf", "fps=\(fps)",
                "-qscale:v", "2",
                pattern
            ]
            do {
                try ffmpeg.run()
                ffmpeg.waitUntilExit()
            } catch {
                logger.error("FFmpeg fallback process failed: \(error)")
            }
            
            if let files = try? FileManager.default.contentsOfDirectory(atPath: thumbnailsDir.path) {
                let matchingPrefix = "\(filename)_frame_"
                logger.info("FFmpeg finished. Scanning directory \(thumbnailsDir.path) for prefix \(matchingPrefix) (total files in dir: \(files.count))")
                let sortedFrames = files.filter { $0.hasPrefix(matchingPrefix) && $0.hasSuffix(".jpg") }.sorted()
                logger.info("Found \(sortedFrames.count) matching frames for \(filename)")
                for (index, frame) in sortedFrames.enumerated() {
                    let ts = Double(index) / fps
                    framesToAnalyze.append((path: thumbnailsDir.appendingPathComponent(frame).path, timestamp: ts))
                }
            } else {
                logger.error("Could not read directory \(thumbnailsDir.path)")
            }
        } else {
            let imageGenerator = AVAssetImageGenerator(asset: asset)
            imageGenerator.requestedTimeToleranceBefore = .zero
            imageGenerator.requestedTimeToleranceAfter = .zero
            imageGenerator.appliesPreferredTrackTransform = true
            let totalFrames = Int(seconds * fps)
            
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
                    framesToAnalyze.append((path: thumbURL.path, timestamp: timestamp))
                } catch {
                    logger.error("Failed to extract frame \(i) via AVFoundation: \(error)")
                }
            }
        }
        return framesToAnalyze
    }

    static func extractAndAnalyze(filename: String, db: Database, logger: Logging.Logger, client: Client) async {
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
        let duration = try? await asset.load(.duration)
        
        var seconds = 0.0
        if let d = duration {
            let rawSeconds = CMTimeGetSeconds(d)
            if !rawSeconds.isNaN && !rawSeconds.isInfinite {
                seconds = rawSeconds
            }
        }
        
        var useFFmpegFallback = false
        if filename.lowercased().hasSuffix(".ts") {
            useFFmpegFallback = true
        } else if seconds > 0.0 {
            let imageGenerator = AVAssetImageGenerator(asset: asset)
            do {
                _ = try await imageGenerator.image(at: CMTime(seconds: 0.1, preferredTimescale: 600))
            } catch {
                useFFmpegFallback = true
            }
        } else {
            useFFmpegFallback = true
        }

        let fps = 1.0
        let thumbnailsDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("../backend/thumbnails/")
        try? FileManager.default.createDirectory(at: thumbnailsDir, withIntermediateDirectories: true)

        async let freezeTask = detectFreeze(videoPath: videoURL.path)
        async let audioTask = analyzeAudio(asset: asset, videoURL: videoURL, useFFmpegFallback: useFFmpegFallback, filename: filename, logger: logger)
        async let framesTask = extractFrames(asset: asset, videoURL: videoURL, useFFmpegFallback: useFFmpegFallback, seconds: seconds, fps: fps, filename: filename, thumbnailsDir: thumbnailsDir, logger: logger)

        let freezeIntervals = await freezeTask
        let (silenceIntervals, hasStatic, hasBuzzing, hasClicking, hasLipSync) = await audioTask
        let framesToAnalyze = await framesTask

        let totalFramesCount = framesToAnalyze.count
        await ExtractionProgress.shared.set(status: "analyzing", current: 0, total: totalFramesCount, for: filename)
        
        var logsToSave: [VideoLog] = []
        var anyVideoFramesSaved = false

        let captureHasStatic = hasStatic
        let captureHasBuzzing = hasBuzzing
        let captureHasClicking = hasClicking
        let captureSilence = silenceIntervals
        let captureHasLipSync = hasLipSync
        let captureFreeze = freezeIntervals
        let finalFrames = framesToAnalyze
        
        let maxConcurrentTasks = ProcessInfo.processInfo.activeProcessorCount * 2
        
        await withTaskGroup(of: (Int, [VideoLog]).self) { group in
            var currentIndex = 0
            var completedCount = 0
            
            func submitTask(for i: Int) {
                let frameData = finalFrames[i]
                group.addTask {
                    let thumbPath = frameData.path
                    let frameName = URL(fileURLWithPath: thumbPath).lastPathComponent
                    let timestamp = frameData.timestamp
                    
                    let cvResults = VisionAnalyzer.analyze(imagePath: thumbPath)
                    var issuesFound: [(String, Double, String)] = []
                    
                    let isSilent = captureSilence.contains { start, end in
                        timestamp >= start && timestamp <= end
                    }
                    if isSilent {
                        issuesFound.append(("no_audio", 1.0, "ffmpeg"))
                    }
                    if captureHasBuzzing { issuesFound.append(("buzzing_audio", 1.0, "ffmpeg")) }
                    if captureHasStatic { issuesFound.append(("static_audio", 1.0, "ffmpeg")) }
                    if captureHasClicking { issuesFound.append(("clicking_audio", 1.0, "ffmpeg")) }
                    
                    var videoIssueFound = false
                    
                    if let cv = cvResults {
                        if cv.isBlackScreen {
                            issuesFound.append(("black_screen", 1.0, "opencv"))
                            videoIssueFound = true
                        } else {
                            let isFrozen = captureFreeze.contains { start, end in
                                timestamp >= start && timestamp <= end
                            }
                            if isFrozen {
                                issuesFound.append(("frozen_screen", 1.0, "ffmpeg"))
                                videoIssueFound = true
                            }
                            if cv.isBars {
                                issuesFound.append(("bars_and_tone", 1.0, "opencv"))
                                videoIssueFound = true
                            }
                            if cv.isSnowflakes {
                                issuesFound.append(("snowflakes", 1.0, "opencv"))
                                videoIssueFound = true
                            }
                            if cv.isBlurry {
                                issuesFound.append(("blur", 1.0, "opencv"))
                                videoIssueFound = true
                            }
                            let macroConfidence = min(1.0, max(0.0, (cv.blockiness - 1.25) / 0.5))
                            if macroConfidence >= 0.50 && cv.laplacianVariance > 30.0 {
                                issuesFound.append(("macroblocking", Double(macroConfidence), "opencv"))
                                videoIssueFound = true
                            }
                            if captureHasLipSync {
                                issuesFound.append(("lip_sync", 0.95, "ffmpeg"))
                                videoIssueFound = true
                            }
                            if cv.hasTopArtifact {
                                issuesFound.append(("top_artifact", 1.0, "opencv"))
                                videoIssueFound = true
                            }
                        }
                    } else {
                        let isFrozen = captureFreeze.contains { start, end in
                            timestamp >= start && timestamp <= end
                        }
                        if isFrozen {
                            issuesFound.append(("frozen_screen", 1.0, "ffmpeg"))
                            videoIssueFound = true
                        }
                        if captureHasLipSync {
                            issuesFound.append(("lip_sync", 0.95, "ffmpeg"))
                            videoIssueFound = true
                        }
                    }
                    
                    if !videoIssueFound && i % 5 == 0 {
                        let (isSlate, conf) = await OllamaClient.analyzeFrame(client: client, imagePath: thumbPath, model: "moondream")
                        if isSlate {
                            issuesFound.append(("slate", conf, "quick_ai"))
                            videoIssueFound = true
                        } else {
                            let (fallbackSlate, fallbackConf) = await OllamaClient.analyzeFrame(client: client, imagePath: thumbPath, model: "llava")
                            if fallbackSlate {
                                issuesFound.append(("slate", fallbackConf, "heavy_ai"))
                            }
                        }
                    }
                    
                    var newLogs: [VideoLog] = []
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
                        newLogs.append(log)
                    }
                    
                    return (i, newLogs)
                }
            }
            
            // Submit initial batch
            for _ in 0..<min(maxConcurrentTasks, finalFrames.count) {
                submitTask(for: currentIndex)
                currentIndex += 1
            }
            
            // Wait for completion and submit remainder
            for await (_, newLogs) in group {
                logsToSave.append(contentsOf: newLogs)
                completedCount += 1
                await ExtractionProgress.shared.set(status: "analyzing", current: completedCount, total: finalFrames.count, for: filename)
                
                if currentIndex < finalFrames.count {
                    submitTask(for: currentIndex)
                    currentIndex += 1
                }
            }
        }
        
        for log in logsToSave {
            try? await log.save(on: db)
            anyVideoFramesSaved = true
        }
        
        let anySilenceLength = silenceIntervals.reduce(0.0) { acc, interval in 
            if interval.1 == .infinity { return acc + 1.0 } else { return acc + (interval.1 - interval.0) } 
        }
        if !anyVideoFramesSaved && anySilenceLength == 0.0 && !hasStatic && !hasBuzzing && !hasClicking {
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
        
        await ExtractionProgress.shared.set(status: "completed", current: totalFramesCount, total: totalFramesCount, for: filename)
        logger.info("Extraction completed for \(filename)")
    }
}
