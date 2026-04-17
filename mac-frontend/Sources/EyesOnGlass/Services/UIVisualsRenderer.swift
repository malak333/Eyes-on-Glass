import Foundation
import CoreVideo
import CoreImage
import SwiftUI
import Combine

class UIVisualsRenderer: @unchecked Sendable {
    private weak var streamController: StreamController?

    init(streamController: StreamController?) {
        self.streamController = streamController
    }

    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private var isRenderingVideo = false
    private let videoQueue = DispatchQueue(label: "com.eyesonGlass.uiVideoRenderer")
    private var isRenderingAudio = false
    private let audioQueue = DispatchQueue(label: "com.eyesonGlass.uiAudioRenderer")

    private var lastVideoRenderTime: TimeInterval = 0
    private var lastAudioRenderTime: TimeInterval = 0

    func render(pixelBuffer: CVPixelBuffer) {
        // Core Animation AVSampleBufferDisplayLayer natively handles its own execution threading and frame drops.
        // Bypassing MainActor to achieve zero-copy propagation!
        streamController?.videoFrameSubject.send(pixelBuffer)
    }

    func render(waveform: [Float], vectorscope: [CGPoint], phase: [Float], levels: [Float]) {
        audioQueue.async {
            let now = CFAbsoluteTimeGetCurrent()
            guard now - self.lastAudioRenderTime >= 1.0 / 30.0 else { return }
            guard !self.isRenderingAudio else { return }
            self.isRenderingAudio = true

            Task {
                let isVisible = await MainActor.run { self.streamController?.isAdvancedInspectorVisible == true }
                if isVisible {
                    await MainActor.run {
                        self.streamController?.audioWaveformData = waveform
                        self.streamController?.audioVectorscopeData = vectorscope
                        self.streamController?.audioPhaseData = phase
                        self.streamController?.audioLevelsData = levels
                    }
                }

                self.audioQueue.async {
                    self.lastAudioRenderTime = CFAbsoluteTimeGetCurrent()
                    self.isRenderingAudio = false
                }
            }
        }
    }
}
