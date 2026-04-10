import SwiftUI

struct AdvancedInspectorView: View {
    @Bindable var streamController: StreamController
    
    var body: some View {
        VStack(spacing: 0) {
            // Top Section: Info text and CC grid
            HStack(alignment: .top, spacing: 16) {
                // Live Video
                ZStack(alignment: .bottomTrailing) {
                    Group {
                        if let image = streamController.currentFrameImage {
                            image
                                .resizable()
                                .scaledToFit()
                        } else {
                            Rectangle()
                                .fill(Color(NSColor.windowBackgroundColor).opacity(0.1))
                                .overlay(Text("No Signal").foregroundColor(.secondary))
                        }
                    }
                    .aspectRatio(16/9, contentMode: .fit)
                    .frame(maxWidth: .infinity, alignment: .top)
                    
                    Button {
                        streamController.toggleMute()
                    } label: {
                        Image(systemName: streamController.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .foregroundColor(.white)
                            .padding(8)
                            .background(Color.black.opacity(0.6))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .padding(12)
                }
                
                // Info Columns
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 12) {
                        InfoGroup(title: "Video Info", items: [
                            ("CODEC", "H.264"),
                            ("PID", streamController.videoPID != nil ? String(streamController.videoPID!) : "-"),
                            ("Aspect", streamController.videoAspect ?? "-"),
                            ("AFD", "Not Present"), // SEI parsed AFD is not currently extracted
                            ("Resolution", streamController.videoResolution != nil ? "\(Int(streamController.videoResolution!.width))x\(Int(streamController.videoResolution!.height))" : "-"),
                            ("Frame Rate", streamController.videoFrameRate != nil && streamController.videoFrameRate! > 0 ? String(format: "%.2f fps", streamController.videoFrameRate!) : "-"),
                            ("Sampling", streamController.videoResolution != nil ? "4:2:0" : "-"), // Standard H264 profile mapping
                            ("Color", streamController.videoColor ?? "-"),
                            ("GOP Size", streamController.videoGOPSize != nil && streamController.videoGOPSize! > 0 ? String(streamController.videoGOPSize!) : "-"),
                            ("V-Chip", "Not Present"), // EIA-708 parsing is not currently implemented
                            ("Bitrate", streamController.streamBitrate > 0 ? String(format: "%.2f mbps", streamController.streamBitrate) : "-")
                        ])
                        
                        InfoGroup(title: "Audio 1 Info", items: [
                            ("CODEC", streamController.audioCodec ?? "-"),
                            ("PID", streamController.audioPID != nil ? String(streamController.audioPID!) : "-"),
                            ("Channels", streamController.audioChannels != nil ? String(streamController.audioChannels!) : "-"),
                            ("Sample Rate", streamController.audioSampleRate != nil ? String(streamController.audioSampleRate!) : "-"),
                            ("Bitrate", streamController.audioBitrate != nil && streamController.audioBitrate! > 0 ? String(format: "%.1f kbps", streamController.audioBitrate!) : "-"),
                            ("Loudness", streamController.audioLoudness != nil ? String(format: "%.1f LUFS", streamController.audioLoudness!) : "-"),
                            ("True Peak", streamController.audioTruePeak != nil ? String(format: "%.1f dBTP", streamController.audioTruePeak!) : "-"),
                            ("Language", "eng"),
                            ("Dial Norm", streamController.audioDialNorm != nil ? String(format: "%d", streamController.audioDialNorm!) : "-")
                        ])
                    }
                    
                    VStack(alignment: .leading, spacing: 12) {
                        InfoGroup(title: "Stream Info", items: [
                            ("Source", streamController.streamSourceType),
                            ("Stream A", "Up"),
                            ("Network", "BACKUP"),
                            ("Dst IP", streamController.streamIP),
                            ("Dst Port", streamController.streamPort),
                            ("Src IP", "-"),
                            ("Src Port", "-")
                        ])
                        
                        InfoGroup(title: "TS Info", items: [
                            ("TS ID", streamController.tsID != nil ? String(streamController.tsID!) : "-"),
                            ("PS ID", streamController.programID != nil ? String(streamController.programID!) : "-"),
                            ("Services", streamController.servicesCount > 0 ? String(streamController.servicesCount) : "-"),
                            ("SDT Channel", streamController.sdtChannel ?? "-"),
                            ("SDT Provider", streamController.sdtProvider ?? "-"),
                            ("TS Clock", streamController.tsClock ?? "-"),
                            ("RX Rate", streamController.streamBitrate > 0 ? String(format: "%.2f mbps", streamController.streamBitrate) : "-"),
                            ("PCR Jitter", streamController.pcrJitter != nil ? String(format: "%.2f ms", streamController.pcrJitter!) : "-"),
                            ("PCR Interval", streamController.pcrInterval != nil ? String(format: "%.2f ms", streamController.pcrInterval!) : "-")
                        ])
                        
                        // Simulated Error Blocks
                        VStack(alignment: .leading, spacing: 4) {
                            GridStack(rows: 3, columns: 8) { row, col in
                                let index = row * 8 + col
                                Rectangle()
                                    .fill(errorColor(index: index))
                                    .frame(width: 14, height: 8)
                            }
                            
                            if streamController.isVBR {
                                Text("Transport stream is VBR")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 2)
                                    .background(Color.red)
                                    .padding(.top, 4)
                            }
                        }
                    }
                }
                .fixedSize(horizontal: true, vertical: false)
                .padding(.leading, 8)
            }
            .padding()
            .font(.system(size: 11, design: .monospaced))
            .foregroundColor(.white)
            
            Spacer(minLength: 20)
            
            // Bottom Section: Visualizers
            HStack(spacing: 16) {
                // Waveform
                VisualizerBox(title: "Waveform") {
                    realWaveform()
                }
                
                // Histogram / Spectrum
                VisualizerBox(title: "Spectrum") {
                    realAudioPhase()
                }
                
                // Vectorscope
                VisualizerBox(title: "Vectorscope") {
                    realVectorscope()
                }
            }
            .padding(.horizontal)
            .padding(.bottom)
            .frame(height: 200)
        }
        .background(Color.black)
        .frame(minWidth: 500)
        .onAppear {
            streamController.isAdvancedInspectorVisible = true
        }
        .onDisappear {
            streamController.isAdvancedInspectorVisible = false
        }
    }
    
    private func errorColor(index: Int) -> Color {
        let errs = streamController.streamCCErrors
        if index < errs {
            return .red
        }
        if index > 15 {
            return Color(NSColor.darkGray)
        }
        return .green
    }
    
    @ViewBuilder
    private func realWaveform() -> some View {
        let data = streamController.audioWaveformData
        Canvas { context, size in
            if data.isEmpty { return }
            
            var path = Path()
            let stepX = size.width / Double(max(1, data.count - 1))
            let yCenter = size.height / 2
            
            for (i, sample) in data.enumerated() {
                let x = Double(i) * stepX
                // Sample is roughly -1.0 to 1.0
                let y = yCenter - Double(sample) * (size.height / 2.0)
                
                if i == 0 {
                    path.move(to: CGPoint(x: x, y: y))
                } else {
                    path.addLine(to: CGPoint(x: x, y: y))
                }
            }
            context.stroke(path, with: .color(.white.opacity(0.8)), lineWidth: 1)
        }
    }
    
    @ViewBuilder
    private func realVectorscope() -> some View {
        let data = streamController.audioVectorscopeData
        ZStack {
            Circle()
                .strokeBorder(Color.gray.opacity(0.3), lineWidth: 1)
                .frame(width: 140, height: 140)
            
            // Crosshairs
            Rectangle().fill(Color.gray.opacity(0.3)).frame(width: 140, height: 1)
            Rectangle().fill(Color.gray.opacity(0.3)).frame(width: 1, height: 140)
            
            Canvas { context, size in
                if data.isEmpty { return }
                
                var path = Path()
                let scale = size.width / 2.0
                
                for (i, pt) in data.enumerated() {
                    // pt.x is left, pt.y is right. Rotate by 45 deg to standard lissajous
                    let x = size.width/2 + Double(pt.y - pt.x) * 0.707 * scale
                    let y = size.height/2 - Double(pt.x + pt.y) * 0.707 * scale
                    
                    if i == 0 {
                        path.move(to: CGPoint(x: x, y: y))
                    } else {
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                }
                context.stroke(path, with: .color(.green.opacity(0.8)), lineWidth: 1)
            }
        }
    }
    
    @ViewBuilder
    private func realAudioPhase() -> some View {
        let data = streamController.audioPhaseData
        Canvas { context, size in
            if data.isEmpty { return }
            
            var path = Path()
            let steps = data.count
            let stepX = size.width / Double(max(1, steps - 1))
            let yCenter = size.height / 2
            
            // Draw 0-line
            context.stroke(Path(CGRect(x: 0, y: yCenter, width: size.width, height: 1)), with: .color(.gray.opacity(0.3)))
            
            for (i, correlation) in data.enumerated() {
                let x = Double(i) * stepX
                // correlation is between -1 and 1
                let y = yCenter - Double(correlation) * (size.height / 2.0)
                
                if i == 0 {
                    path.move(to: CGPoint(x: x, y: y))
                } else {
                    path.addLine(to: CGPoint(x: x, y: y))
                }
            }
            
            context.stroke(path, with: .color(.cyan.opacity(0.8)), lineWidth: 2)
        }
    }
}

// Reusable component for the groups of technical stats
struct InfoGroup: View {
    let title: String
    let items: [(String, String)]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.white)
                .padding(.bottom, 4)
            
            ForEach(items, id: \.0) { item in
                HStack {
                    Text(item.0)
                        .foregroundColor(.gray)
                        .frame(width: 85, alignment: .leading)
                        .lineLimit(1)
                    Text(item.1)
                        .foregroundColor(.white)
                        .lineLimit(1)
                }
            }
        }
    }
}

// Simple Grid Builder
struct GridStack<Content: View>: View {
    let rows: Int
    let columns: Int
    @ViewBuilder let content: (Int, Int) -> Content
    
    var body: some View {
        VStack(spacing: 2) {
            ForEach(0..<rows, id: \.self) { row in
                HStack(spacing: 2) {
                    ForEach(0..<columns, id: \.self) { column in
                        content(row, column)
                    }
                }
            }
        }
    }
}

struct VisualizerBox<Content: View>: View {
    let title: String
    let content: Content
    
    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(.gray)
                .padding([.top, .leading], 6)
            
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(NSColor.darkGray).opacity(0.2))
        .border(Color(NSColor.darkGray), width: 1)
    }
}
