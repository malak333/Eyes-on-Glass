import Foundation
import CoreImage
import Accelerate
import AVFoundation

func testVideo(path: String) {
    let url = URL(fileURLWithPath: path)
    let asset = AVAsset(url: url)
    let imageGenerator = AVAssetImageGenerator(asset: asset)
    imageGenerator.appliesPreferredTrackTransform = true
    imageGenerator.requestedTimeToleranceBefore = .zero
    imageGenerator.requestedTimeToleranceAfter = .zero
    
    do {
        let maxFrames = 5
        for i in 1...maxFrames {
            let time = CMTime(seconds: Double(i), preferredTimescale: 600)
            let cgImage = try imageGenerator.copyCGImage(at: time, actualTime: nil)
            
            let colorSpace = CGColorSpaceCreateDeviceGray()
            var format = vImage_CGImageFormat(
                bitsPerComponent: 8,
                bitsPerPixel: 8,
                colorSpace: Unmanaged.passUnretained(colorSpace),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                version: 0, decode: nil, renderingIntent: .defaultIntent
            )
            var sourceBuffer = vImage_Buffer()
            vImageBuffer_InitWithCGImage(&sourceBuffer, &format, nil, cgImage, vImage_Flags(kvImageNoFlags))
            guard let gb = sourceBuffer.data?.assumingMemoryBound(to: UInt8.self) else { continue }
            let rowBytes = sourceBuffer.rowBytes
            let width = Int(sourceBuffer.width)
            let height = Int(sourceBuffer.height)
            
            var sum: Float = 0
            var sqSum: Float = 0
            var lapSum: Float = 0
            var lapSqSum: Float = 0
            var lapCount = 0

            var hDiffBound8: Float = 0, hDiffNonBound8: Float = 0
            var hBCount8 = 0, hNBCount8 = 0
            var vDiffBound8: Float = 0, vDiffNonBound8: Float = 0
            var vBCount8 = 0, vNBCount8 = 0
            var hDiffBound16: Float = 0, hDiffNonBound16: Float = 0
            var hBCount16 = 0, hNBCount16 = 0
            var vDiffBound16: Float = 0, vDiffNonBound16: Float = 0
            var vBCount16 = 0, vNBCount16 = 0

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
                    }

                    if x < width - 1 {
                        let diffH = abs(Float(gb[r + x + 1]) - v)
                        if (x + 1) % 8 == 0 { hDiffBound8 += diffH; hBCount8 += 1 } else { hDiffNonBound8 += diffH; hNBCount8 += 1 }
                        if (x + 1) % 16 == 0 { hDiffBound16 += diffH; hBCount16 += 1 } else { hDiffNonBound16 += diffH; hNBCount16 += 1 }
                    }
                    if y < height - 1 {
                        let diffV = abs(Float(gb[nr + x]) - v)
                        if (y + 1) % 8 == 0 { vDiffBound8 += diffV; vBCount8 += 1 } else { vDiffNonBound8 += diffV; vNBCount8 += 1 }
                        if (y + 1) % 16 == 0 { vDiffBound16 += diffV; vBCount16 += 1 } else { vDiffNonBound16 += diffV; vNBCount16 += 1 }
                    }
                }
            }
            
            let totalPixels = Float(width * height)
            let meanBrightness = sum / totalPixels
            let stdDev = sqrt(max(0, (sqSum / totalPixels) - (meanBrightness * meanBrightness)))
            
            let mLap = lapSum / Float(max(1, lapCount))
            let laplacianVar = (lapSqSum / Float(max(1, lapCount))) - (mLap * mLap)
            
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
            
            let blockiness = max(max(blockX8, blockY8), max(blockX16, blockY16))
            
            print("[\(path) @ \(i)s] stdDev: \(String(format:"%.2f", stdDev)), lapVar: \(String(format:"%.2f", laplacianVar)), blockiness: \(String(format:"%.4f", blockiness))")
            free(sourceBuffer.data)
        }
    } catch {
        print("Error: \(error)")
    }
}

let args = CommandLine.arguments
if args.count > 1 {
    for i in 1..<args.count {
        testVideo(path: args[i])
    }
}
