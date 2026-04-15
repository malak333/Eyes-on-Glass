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
            return ValidationMetrics(meanBrightness: 0, isBlackScreen: false, laplacianVariance: 0, isBlurry: false, blockiness: 1.0, macroConfidence: 0.0, hasTopArtifact: false, isBars: false, isSnowflakes: false, anomalyBoundingBoxes: [])
        }
        
        var sum: Float = 0
        var sqSum: Float = 0

        var lapSum: Float = 0
        var lapSqSum: Float = 0
        var lapCount = 0
        
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

        // Fused Analysis Pass
        for y in 0..<height {
            let r = y * rowBytes
            let pr = max(0, y - 1) * rowBytes
            let nr = min(height - 1, y + 1) * rowBytes

            for x in 0..<width {
                let v = Float(gb[r + x])
                sum += v
                sqSum += v * v

                if y > 0 && y < height - 1 && x > 0 && x < width - 1 {
                    let c = v
                    let l = Float(gb[r + x - 1])
                    let rt = Float(gb[r + x + 1])
                    let u = Float(gb[pr + x])
                    let d = Float(gb[nr + x])
                    
                    let lap = l + rt + u + d - 4 * c
                    lapSum += lap
                    lapSqSum += lap * lap
                    lapCount += 1
                    
                    if y < 10 {
                        topLapSum += lap
                        topLapSqSum += lap * lap
                        topCount += 1
                    }

                    let tl = Float(gb[pr + x - 1])
                    let tr = Float(gb[pr + x + 1])
                    let bl = Float(gb[nr + x - 1])
                    let br = Float(gb[nr + x + 1])
                    
                    let gx = (tr + 2*rt + br) - (tl + 2*l + bl)
                    sxSum += gx
                    sxSqSum += gx * gx
                    
                    let gy = (bl + 2*d + br) - (tl + 2*u + tr)
                    sySum += gy
                    sySqSum += gy * gy
                    
                    sCount += 1
                }

                if x < width - 1 {
                    let diffH = abs(Float(gb[r + x + 1]) - v)
                    if (x + 1) % 8 == 0 {
                        hDiffBound8 += diffH
                        hBCount8 += 1
                    } else {
                        hDiffNonBound8 += diffH
                        hNBCount8 += 1
                    }
                    
                    if (x + 1) % 16 == 0 {
                        hDiffBound16 += diffH
                        hBCount16 += 1
                    } else {
                        hDiffNonBound16 += diffH
                        hNBCount16 += 1
                    }
                }

                if y < height - 1 {
                    let diffV = abs(Float(gb[nr + x]) - v)
                    if (y + 1) % 8 == 0 {
                        vDiffBound8 += diffV
                        vBCount8 += 1
                    } else {
                        vDiffNonBound8 += diffV
                        vNBCount8 += 1
                    }
                    
                    if (y + 1) % 16 == 0 {
                        vDiffBound16 += diffV
                        vBCount16 += 1
                    } else {
                        vDiffNonBound16 += diffV
                        vNBCount16 += 1
                    }
                }
            }
        }
        
        let totalPixels = Float(width * height)
        let meanBrightness = sum / totalPixels
        let variance = (sqSum / totalPixels) - (meanBrightness * meanBrightness)
        let stdDev = sqrt(max(0, variance))
        let isBlackScreen = meanBrightness < 5.0
        
        let mLap = lapSum / Float(max(1, lapCount))
        let laplacianVar = (lapSqSum / Float(max(1, lapCount))) - (mLap * mLap)
        
        let isBlurry = laplacianVar < 100.0 && stdDev > 10.0
        
        let tLap = topLapSum / Float(max(1, topCount))
        let topLaplacianVar = (topLapSqSum / Float(max(1, topCount))) - (tLap * tLap)
        let hasTopArtifact = topLaplacianVar > 1000.0 && (topLaplacianVar > laplacianVar * 5.0 || isBlackScreen)
        
        let cF = Float(max(1, sCount))
        let mX = sxSum / cF
        let varX = max(0, (sxSqSum / cF) - (mX * mX))
        let mY = sySum / cF
        let varY = max(0, (sySqSum / cF) - (mY * mY))
        
        let isBars = varY < 100.0 && varX > 1000.0 && varX > varY * 10.0
        
        let hBM8 = hDiffBound8 / Float(max(1, hBCount8))
        let hNBM8 = hDiffNonBound8 / Float(max(1, hNBCount8))
        let blockX8 = hBM8 / (hNBM8 + 1e-5)
        
        let vBM8 = vDiffBound8 / Float(max(1, vBCount8))
        let vNBM8 = vDiffNonBound8 / Float(max(1, vNBCount8))
        let blockY8 = vBM8 / (vNBM8 + 1e-5)
        
        let hBM16 = hDiffBound16 / Float(max(1, hBCount16))
        let hNBM16 = hDiffNonBound16 / Float(max(1, hNBCount16))
        let blockX16 = hBM16 / (hNBM16 + 1e-5)
        
        let vBM16 = vDiffBound16 / Float(max(1, vBCount16))
        let vNBM16 = vDiffNonBound16 / Float(max(1, vNBCount16))
        let blockY16 = vBM16 / (vNBM16 + 1e-5)
        
        let maxBlock8 = max(blockX8, blockY8)
        let maxBlock16 = max(blockX16, blockY16)
        
        let blockiness = max(maxBlock8, maxBlock16)
        
        let isSnowflakes = stdDev > 30.0 && laplacianVar > 2000.0 && blockiness < 2.0 && (max(varX, varY) > 0 ? abs(varX - varY) / max(varX, varY) < 0.2 : false)
        
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
            anomalyBoundingBoxes: anomalyBoundingBoxes
        )
    }
    
    private static func extractAnomalyBoundingBoxes(gb: UnsafePointer<UInt8>, width: Int, height: Int, rowBytes: Int) -> [CGRect] {
        var boxes: [CGRect] = []
        let blockSize = 32
        let blocksX = width / blockSize
        let blocksY = height / blockSize
        
        for by in 0..<blocksY {
            for bx in 0..<blocksX {
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
                
                if lapCount > 0 {
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
                            let rect = CGRect(
                                x: CGFloat(startX) / CGFloat(width),
                                y: CGFloat(startY) / CGFloat(height),
                                width: CGFloat(blockSize) / CGFloat(width),
                                height: CGFloat(blockSize) / CGFloat(height)
                            )
                            boxes.append(rect)
                        }
                    }
                }
            }
        }
        
        if boxes.count > 30 {
            boxes = Array(boxes.prefix(30))
        }
        return boxes
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
