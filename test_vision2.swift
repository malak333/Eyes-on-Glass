import Foundation
import CoreImage
import Accelerate

func getBlockiness(imagePath: String) {
    let uiImageURL = URL(fileURLWithPath: imagePath)
    let ciImage = CIImage(contentsOf: uiImageURL)!
    let context = CIContext(options: [.cacheIntermediates: false])
    let cgImage = context.createCGImage(ciImage, from: ciImage.extent)!

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
    guard let gb = sourceBuffer.data?.assumingMemoryBound(to: UInt8.self) else { return }
    let rowBytes = sourceBuffer.rowBytes
    let width = Int(sourceBuffer.width)
    let height = Int(sourceBuffer.height)

    var hDiffBound8: Float = 0, hDiffNonBound8: Float = 0
    var hBCount8 = 0, hNBCount8 = 0

    for y in 0..<height {
        let r = y * rowBytes
        for x in 0..<width - 1 {
            let v = Float(gb[r + x])
            let diffH = abs(Float(gb[r + x + 1]) - v)
            if (x + 1) % 8 == 0 {
                hDiffBound8 += diffH
                hBCount8 += 1
            } else {
                hDiffNonBound8 += diffH
                hNBCount8 += 1
            }
        }
    }
    
    let hBM8 = hDiffBound8 / Float(max(1, hBCount8))
    let hNBM8 = hDiffNonBound8 / Float(max(1, hNBCount8))
    let blockX8 = hBM8 / (hNBM8 + 1e-5)
    
    print("hBM8: \(hBM8), hNBM8: \(hNBM8), blockX8: \(blockX8)")
}

getBlockiness(imagePath: CommandLine.arguments[1])
