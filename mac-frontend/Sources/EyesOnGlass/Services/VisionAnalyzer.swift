import Foundation
import CoreImage
import Accelerate
import ImageIO

struct ValidationMetrics: Sendable {
    var meanBrightness: Float
    var isBlackScreen: Bool
    var laplacianVariance: Float
    var isBlurry: Bool
    var blockiness: Float
    var macroConfidence: Float
    var hasTopArtifact: Bool
    var isBars: Bool
    var isSnowflakes: Bool
    var anomalyBoundingBoxes: [CGRect]
    var isGraphic: Bool
    
    var isDefinitivelyMacroblocked: Bool {
        // Exclude fade-to-black/dark scenes which falsely boost codec blockiness
        let isDarkScene = meanBrightness < 25.0
        
        let hasBaseMacro = macroConfidence >= 0.35 && laplacianVariance > 15.0 && anomalyBoundingBoxes.count >= 4
        
        // If the macroblocking signal is exceptionally strong, it overrides the graphic gate false-positives
        // We set these thresholds exceptionally high so sharp text animations on slates don't trigger it
        let hasSevereMacro = anomalyBoundingBoxes.count >= 20 || blockiness > 4.0
        
        return hasBaseMacro && (!isGraphic || hasSevereMacro) && !isDarkScene
    }
}

struct VisionAnalyzer: Sendable {
    static func analyze(cgImage: CGImage) -> ValidationMetrics? {
        let colorSpace = CGColorSpaceCreateDeviceGray()
        var format = vImage_CGImageFormat(
            bitsPerComponent: 8,
            bitsPerPixel: 8,
            colorSpace: Unmanaged.passUnretained(colorSpace),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            version: 0,
            decode: nil,
            renderingIntent: .defaultIntent
        )
        
        var sourceBuffer = vImage_Buffer()
        let error = vImageBuffer_InitWithCGImage(&sourceBuffer, &format, nil, cgImage, vImage_Flags(kvImageNoFlags))
        if error != kvImageNoError { return nil }
        defer { free(sourceBuffer.data) }
        
        guard let gb = sourceBuffer.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let rowBytes = sourceBuffer.rowBytes
        let width = Int(sourceBuffer.width)
        let height = Int(sourceBuffer.height)
        
        if width < 16 || height < 16 {
            return ValidationMetrics(meanBrightness: 0, isBlackScreen: false, laplacianVariance: 0, isBlurry: false, blockiness: 1.0, macroConfidence: 0.0, hasTopArtifact: false, isBars: false, isSnowflakes: false, anomalyBoundingBoxes: [], isGraphic: false)
        }
        
        var stats = AnalysisStats()

        // Fused Analysis Pass
        for y in 0..<height {
            let r = y * rowBytes
            let pr = max(0, y - 1) * rowBytes
            let nr = min(height - 1, y + 1) * rowBytes

            for x in 0..<width {
                let v = Float(gb[r + x])
                stats.sum += v
                stats.sqSum += v * v

                if y > 0 && y < height - 1 && x > 0 && x < width - 1 {
                    processLaplacianAndGradient(gb: gb, x: x, y: y, rowBytes: rowBytes, pr: pr, nr: nr, v: v, stats: &stats)
                }

                processBlockiness(gb: gb, x: x, y: y, rowBytes: rowBytes, nr: nr, v: v, width: width, height: height, stats: &stats)
            }
        }

        return calculateFinalMetrics(stats: stats, width: width, height: height, gb: gb, rowBytes: rowBytes)
    }

    private struct AnalysisStats {
        var sum: Float = 0
        var sqSum: Float = 0
        var lapSum: Float = 0
        var lapSqSum: Float = 0
        var lapCount = 0
        var zeroGradientCount = 0
        var topLapSum: Float = 0
        var topLapSqSum: Float = 0
        var topCount = 0
        var sxSum: Float = 0
        var sxSqSum: Float = 0
        var sySum: Float = 0
        var sySqSum: Float = 0
        var sCount = 0
        var hDiffBound8: Float = 0
        var hDiffNonBound8: Float = 0
        var hBCount8 = 0, hNBCount8 = 0
        var hDiffBound16: Float = 0
        var hDiffNonBound16: Float = 0
        var hBCount16 = 0, hNBCount16 = 0
        var vDiffBound8: Float = 0
        var vDiffNonBound8: Float = 0
        var vBCount8 = 0, vNBCount8 = 0
        var vDiffBound16: Float = 0
        var vDiffNonBound16: Float = 0
        var vBCount16 = 0, vNBCount16 = 0
    }

    private static func processLaplacianAndGradient(gb: UnsafePointer<UInt8>, x: Int, y: Int, rowBytes: Int, pr: Int, nr: Int, v: Float, stats: inout AnalysisStats) {
        let c = v
        let l = Float(gb[y * rowBytes + x - 1])
        let rt = Float(gb[y * rowBytes + x + 1])
        let u = Float(gb[pr + x])
        let d = Float(gb[nr + x])

        let lap = l + rt + u + d - 4 * c
        stats.lapSum += lap
        stats.lapSqSum += lap * lap
        stats.lapCount += 1

        if abs(lap) <= 2.0 {
            stats.zeroGradientCount += 1
        }

        if y < 10 {
            stats.topLapSum += lap
            stats.topLapSqSum += lap * lap
            stats.topCount += 1
        }

        let tl = Float(gb[pr + x - 1])
        let tr = Float(gb[pr + x + 1])
        let bl = Float(gb[nr + x - 1])
        let br = Float(gb[nr + x + 1])

        let gx = (tr + 2*rt + br) - (tl + 2*l + bl)
        stats.sxSum += gx
        stats.sxSqSum += gx * gx

        let gy = (bl + 2*d + br) - (tl + 2*u + tr)
        stats.sySum += gy
        stats.sySqSum += gy * gy

        stats.sCount += 1
    }

    private static func processBlockiness(gb: UnsafePointer<UInt8>, x: Int, y: Int, rowBytes: Int, nr: Int, v: Float, width: Int, height: Int, stats: inout AnalysisStats) {
        if x < width - 1 {
            let diffH = abs(Float(gb[y * rowBytes + x + 1]) - v)
            if (x + 1) % 8 == 0 {
                stats.hDiffBound8 += diffH
                stats.hBCount8 += 1
            } else {
                stats.hDiffNonBound8 += diffH
                stats.hNBCount8 += 1
            }

            if (x + 1) % 16 == 0 {
                stats.hDiffBound16 += diffH
                stats.hBCount16 += 1
            } else {
                stats.hDiffNonBound16 += diffH
                stats.hNBCount16 += 1
            }
        }

        if y < height - 1 {
            let diffV = abs(Float(gb[nr + x]) - v)
            if (y + 1) % 8 == 0 {
                stats.vDiffBound8 += diffV
                stats.vBCount8 += 1
            } else {
                stats.vDiffNonBound8 += diffV
                stats.vNBCount8 += 1
            }

            if (y + 1) % 16 == 0 {
                stats.vDiffBound16 += diffV
                stats.vBCount16 += 1
            } else {
                stats.vDiffNonBound16 += diffV
                stats.vNBCount16 += 1
            }
        }
    }

    private static func calculateFinalMetrics(stats: AnalysisStats, width: Int, height: Int, gb: UnsafePointer<UInt8>, rowBytes: Int) -> ValidationMetrics {
        let totalPixels = Float(width * height)
        let meanBrightness = stats.sum / totalPixels
        let variance = (stats.sqSum / totalPixels) - (meanBrightness * meanBrightness)
        let stdDev = sqrt(max(0, variance))
        let isBlackScreen = meanBrightness < 5.0
        
        let mLap = stats.lapSum / Float(max(1, stats.lapCount))
        let laplacianVar = (stats.lapSqSum / Float(max(1, stats.lapCount))) - (mLap * mLap)
        
        let isBlurry = laplacianVar < 100.0 && stdDev > 10.0
        
        let tLap = stats.topLapSum / Float(max(1, stats.topCount))
        let topLaplacianVar = (stats.topLapSqSum / Float(max(1, stats.topCount))) - (tLap * tLap)
        let hasTopArtifact = topLaplacianVar > 1000.0 && (topLaplacianVar > laplacianVar * 5.0 || isBlackScreen)
        
        let cF = Float(max(1, stats.sCount))
        let mX = stats.sxSum / cF
        let varX = max(0, (stats.sxSqSum / cF) - (mX * mX))
        let mY = stats.sySum / cF
        let varY = max(0, (stats.sySqSum / cF) - (mY * mY))
        
        let isBars = varY < 100.0 && varX > 1000.0 && varX > varY * 10.0
        
        let blockiness = calculateBlockiness(stats: stats)
        
        let isSnowflakes = stdDev > 30.0 && laplacianVar > 2000.0 && blockiness < 2.0 && (max(varX, varY) > 0 ? abs(varX - varY) / max(varX, varY) < 0.2 : false)
        
        let flatnessRatio = Float(stats.zeroGradientCount) / Float(max(1, stats.lapCount))
        let isGraphic = flatnessRatio > 0.15 && meanBrightness > 5.0
        
        var anomalyBoundingBoxes: [CGRect] = []
        let macroConf = min(1.0, max(0.0, (blockiness - 1.25) / 0.5))
        if macroConf > 0.05 && laplacianVar > 15.0 {
            anomalyBoundingBoxes = extractAnomalyBoundingBoxes(gb: gb, width: width, height: height, rowBytes: rowBytes)
        }
        
        return ValidationMetrics(
            meanBrightness: meanBrightness,
            isBlackScreen: isBlackScreen,
            laplacianVariance: laplacianVar,
            isBlurry: isBlurry,
            blockiness: blockiness,
            macroConfidence: macroConf,
            hasTopArtifact: hasTopArtifact,
            isBars: isBars,
            isSnowflakes: isSnowflakes,
            anomalyBoundingBoxes: anomalyBoundingBoxes,
            isGraphic: isGraphic
        )
    }
    
    private static func calculateBlockiness(stats: AnalysisStats) -> Float {
        let hBM8 = stats.hDiffBound8 / Float(max(1, stats.hBCount8))
        let hNBM8 = stats.hDiffNonBound8 / Float(max(1, stats.hNBCount8))
        let blockX8 = hBM8 / (hNBM8 + 1e-5)

        let vBM8 = stats.vDiffBound8 / Float(max(1, stats.vBCount8))
        let vNBM8 = stats.vDiffNonBound8 / Float(max(1, stats.vNBCount8))
        let blockY8 = vBM8 / (vNBM8 + 1e-5)

        let hBM16 = stats.hDiffBound16 / Float(max(1, stats.hBCount16))
        let hNBM16 = stats.hDiffNonBound16 / Float(max(1, stats.hNBCount16))
        let blockX16 = hBM16 / (hNBM16 + 1e-5)

        let vBM16 = stats.vDiffBound16 / Float(max(1, stats.vBCount16))
        let vNBM16 = stats.vDiffNonBound16 / Float(max(1, stats.vNBCount16))
        let blockY16 = vBM16 / (vNBM16 + 1e-5)

        return max(max(blockX8, blockY8), max(blockX16, blockY16))
    }

    private static func extractAnomalyBoundingBoxes(gb: UnsafePointer<UInt8>, width: Int, height: Int, rowBytes: Int) -> [CGRect] {
        var boxes: [CGRect] = []
        let blockSize = 32
        let blocksX = width / blockSize
        let blocksY = height / blockSize
        
        for by in 0..<blocksY {
            for bx in 0..<blocksX {
                if let rect = processBlock(gb: gb, bx: bx, by: by, blockSize: blockSize, width: width, height: height, rowBytes: rowBytes) {
                    boxes.append(rect)
                }
            }
        }
        
        if boxes.count > 30 {
            boxes = Array(boxes.prefix(30))
        }
        return boxes
    }
    
    private static func processBlock(gb: UnsafePointer<UInt8>, bx: Int, by: Int, blockSize: Int, width: Int, height: Int, rowBytes: Int) -> CGRect? {
        let startX = bx * blockSize
        let startY = by * blockSize

        var lapSum: Float = 0
        var lapSqSum: Float = 0
        var lapCount = 0

        for y in startY..<(startY + blockSize) {
            if y == 0 || y >= height - 1 { continue }
            let r = y * rowBytes
            let pr = (y - 1) * rowBytes
            let nr = (y + 1) * rowBytes

            for x in startX..<(startX + blockSize) {
                if x == 0 || x >= width - 1 { continue }
                let c = Float(gb[r + x])
                let l = Float(gb[r + x - 1])
                let rt = Float(gb[r + x + 1])
                let u = Float(gb[pr + x])
                let d = Float(gb[nr + x])

                let lap = l + rt + u + d - 4 * c
                lapSum += lap
                lapSqSum += lap * lap
                lapCount += 1
            }
        }

        guard lapCount > 0 else { return nil }

        let mLap = lapSum / Float(lapCount)
        let lapVar = (lapSqSum / Float(lapCount)) - (mLap * mLap)

        if lapVar > 15.0 {
            var hDiffBound: Float = 0
            var hDiffNonBound: Float = 0
            var hBCount = 0, hNBCount = 0
            for y in startY..<(startY + blockSize) {
                let r = y * rowBytes
                for x in startX..<(startX + blockSize - 1) {
                    let diffH = abs(Float(gb[r + x + 1]) - Float(gb[r + x]))
                    if (x + 1) % 16 == 0 || (x + 1) % 8 == 0 {
                        hDiffBound += diffH
                        hBCount += 1
                    } else {
                        hDiffNonBound += diffH
                        hNBCount += 1
                    }
                }
            }

            var vDiffBound: Float = 0
            var vDiffNonBound: Float = 0
            var vBCount = 0, vNBCount = 0
            for y in startY..<(startY + blockSize - 1) {
                let r = y * rowBytes
                let nr = (y + 1) * rowBytes
                for x in startX..<(startX + blockSize) {
                    let diffV = abs(Float(gb[nr + x]) - Float(gb[r + x]))
                    if (y + 1) % 16 == 0 || (y + 1) % 8 == 0 {
                        vDiffBound += diffV
                        vBCount += 1
                    } else {
                        vDiffNonBound += diffV
                        vNBCount += 1
                    }
                }
            }

            let hBM = hDiffBound / Float(max(1, hBCount))
            let hNBM = hDiffNonBound / Float(max(1, hNBCount))
            let blockX = hBM / (hNBM + 1e-5)

            let vBM = vDiffBound / Float(max(1, vBCount))
            let vNBM = vDiffNonBound / Float(max(1, vNBCount))
            let blockY = vBM / (vNBM + 1e-5)

            let blockiness = max(blockX, blockY)
            let macroConf = min(1.0, max(0.0, (blockiness - 1.25) / 0.5))
            if macroConf > 0.05 {
                return CGRect(
                    x: CGFloat(startX) / CGFloat(width),
                    y: CGFloat(startY) / CGFloat(height),
                    width: CGFloat(blockSize) / CGFloat(width),
                    height: CGFloat(blockSize) / CGFloat(height)
                )
            }
        }
        return nil
    }

    static func analyze(imagePath: String) -> ValidationMetrics? {
        let uiImageURL = URL(fileURLWithPath: imagePath)
        let context = CIContext(options: [.cacheIntermediates: false])
        guard let ciImage = CIImage(contentsOf: uiImageURL) else { return nil }
        return analyze(ciImage: ciImage, context: context)
    }
    
    static func analyze(ciImage: CIImage, context: CIContext) -> ValidationMetrics? {
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return nil }
        return analyze(cgImage: cgImage)
    }
}
