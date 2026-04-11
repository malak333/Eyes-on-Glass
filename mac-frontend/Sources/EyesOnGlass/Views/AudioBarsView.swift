import SwiftUI

struct AudioBarsView: View {
    var audioLevels: [Float]
    
    @State private var peaks: [Float] = []
    
    let timer = Timer.publish(every: 0.033, on: .main, in: .common).autoconnect()
    
    var body: some View {
        Canvas { context, size in
            let count = max(audioLevels.count, 1)
            let totalWidth = size.width
            let spacing: CGFloat = 4
            let barWidth = max(2, (totalWidth - CGFloat(count + 1) * spacing) / CGFloat(count))
            let maxH = size.height - 15
            
            for i in 0..<audioLevels.count {
                let x = spacing + CGFloat(i) * (barWidth + spacing)
                let level = CGFloat(audioLevels[i])
                let hold = CGFloat(i < peaks.count ? peaks[i] : 0)
                
                let h = maxH * level
                let holdH = maxH * hold
                
                // Draw background
                context.fill(Path(CGRect(x: x, y: 0, width: barWidth, height: maxH)), with: .color(Color(NSColor.darkGray).opacity(0.3)))
                
                // Draw bar (gradient-like split could be done, but solid color based on level is fine)
                let barRect = CGRect(x: x, y: maxH - h, width: barWidth, height: h)
                context.fill(Path(barRect), with: .color(colorFor(level: Float(level))))
                
                // Draw peak hold line
                let holdRect = CGRect(x: x, y: maxH - holdH, width: barWidth, height: 2)
                context.fill(Path(holdRect), with: .color(.white))
                
                // Draw label
                let label = channelLabel(for: audioLevels.count, index: i)
                context.draw(Text(label).font(.system(size: 9)).foregroundColor(.gray), at: CGPoint(x: x + barWidth/2, y: size.height - 5))
            }
        }
        .onChange(of: audioLevels) { oldVal, newVal in
            // Handle array resizing
            if peaks.count != newVal.count {
                peaks = Array(repeating: 0.0, count: newVal.count)
            }
            for i in 0..<newVal.count {
                if newVal[i] >= peaks[i] {
                    // Instantly snap up
                    peaks[i] = newVal[i]
                }
            }
        }
        .onReceive(timer) { _ in
            for i in 0..<peaks.count {
                // Smooth decay
                peaks[i] -= 0.01
                if peaks[i] < 0 { peaks[i] = 0.0 }
            }
        }
    }
    
    private func colorFor(level: Float) -> Color {
        if level > 0.90 { return .red }
        if level > 0.75 { return .yellow }
        return .green
    }
    
    private let labels51 = ["L", "R", "C", "LFE", "Ls", "Rs"]
    private let labelsStereo = ["L", "R"]
    private let labelsMono = ["C"]
    
    private func channelLabel(for count: Int, index: Int) -> String {
        if count == 6 && index < 6 { return labels51[index] }
        if count == 2 && index < 2 { return labelsStereo[index] }
        if count == 1 { return labelsMono[0] }
        return "CH\(index + 1)"
    }
}
