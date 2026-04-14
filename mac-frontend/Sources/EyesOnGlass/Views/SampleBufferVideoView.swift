import SwiftUI
import AVFoundation
import Combine

struct SampleBufferVideoView: NSViewRepresentable {
    let frameStream: AnyPublisher<CVPixelBuffer, Never>
    
    class Coordinator {
        let displayLayer = AVSampleBufferDisplayLayer()
        var cancellable: AnyCancellable?
        
        init() {
            displayLayer.videoGravity = .resizeAspect
            // Core Animation prefers this flag natively to avoid color-matching overhead where unnecessary
            displayLayer.isOpaque = true
        }
        
        func enqueue(pixelBuffer: CVPixelBuffer) {
            var formatDesc: CMVideoFormatDescription?
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescriptionOut: &formatDesc)
            guard let formatDesc = formatDesc else { return }
            
            var timingInfo = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
            var sampleBuffer: CMSampleBuffer?
            
            CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
                                                     imageBuffer: pixelBuffer,
                                                     formatDescription: formatDesc,
                                                     sampleTiming: &timingInfo,
                                                     sampleBufferOut: &sampleBuffer)
            
            if let sampleBuffer = sampleBuffer {
                if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true) {
                    let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
                    CFDictionarySetValue(dict, unsafeBitCast(kCMSampleAttachmentKey_DisplayImmediately, to: UnsafeRawPointer.self), unsafeBitCast(kCFBooleanTrue, to: UnsafeRawPointer.self))
                }
                
                if displayLayer.status == .failed {
                    displayLayer.flush()
                }
                
                // Hardware layer accepts payload directly. No MainActor required for queue injection!
                displayLayer.enqueue(sampleBuffer)
            }
        }
    }
    
    func makeCoordinator() -> Coordinator {
        return Coordinator()
    }
    
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        
        let displayLayer = context.coordinator.displayLayer
        view.layer?.addSublayer(displayLayer)
        
        context.coordinator.cancellable = frameStream
            .sink { pixelBuffer in
                context.coordinator.enqueue(pixelBuffer: pixelBuffer)
            }
        
        return view
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.displayLayer.frame = nsView.bounds
    }
}
