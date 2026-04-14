import SwiftUI

struct AudioBarsView: View {
    var audioLevels: [Float]
    
    @State private var peaks: [Float] = Array(repeating: 0.0, count: 16)
    
    let timer = Timer.publish(every: 0.033, on: .main, in: .common).autoconnect()
    
    var body: some View {
        Canvas { context, size in
            let count = 16
            let totalWidth = size.width
            let pairSpacing: CGFloat = 8
            let barSpacing: CGFloat = 2
            let edgePadding: CGFloat = 4
            let numberOfPairs = 8
            
            let totalFixedSpace = (CGFloat(numberOfPairs) * barSpacing) + (CGFloat(numberOfPairs - 1) * pairSpacing) + (2 * edgePadding)
            let barWidth = max(2, (totalWidth - totalFixedSpace) / CGFloat(count))
            let maxH = size.height - 15
            
            for i in 0..<count {
                let pairIndex = i / 2
                let isRightChannel = i % 2 == 1
                
                let x = edgePadding + 
                        CGFloat(pairIndex) * (2 * barWidth + barSpacing + pairSpacing) + 
                        (isRightChannel ? (barWidth + barSpacing) : 0)
                
                let level = CGFloat(i < audioLevels.count ? audioLevels[i] : 0.0)
                let hold = CGFloat(i < peaks.count ? peaks[i] : 0)
                
                let h = maxH * level
                let holdH = maxH * hold
                
                // Draw background
                context.fill(Path(CGRect(x: x, y: 0, width: barWidth, height: maxH)), with: .color(Color(NSColor.darkGray).opacity(0.3)))
                
                // Draw bar
                let barRect = CGRect(x: x, y: maxH - h, width: barWidth, height: h)
                context.fill(Path(barRect), with: .color(colorFor(level: Float(level))))
                
                // Draw peak hold line
                let holdRect = CGRect(x: x, y: maxH - holdH, width: barWidth, height: 2)
                context.fill(Path(holdRect), with: .color(.white))
                
                // Draw label
                let label = channelLabel(for: audioLevels.count, index: i)
                context.draw(Text(label).font(.system(size: 8)).foregroundColor(.gray), at: CGPoint(x: x + barWidth/2, y: size.height - 5))
            }
        }
        .onChange(of: audioLevels) { oldVal, newVal in
            for i in 0..<min(newVal.count, 16) {
                if newVal[i] >= peaks[i] {
                    peaks[i] = newVal[i]
                }
            }
        }
        .onReceive(timer) { _ in
            for i in 0..<peaks.count {
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
        if count == 1 && index == 0 { return labelsMono[0] }
        return "\(index + 1)"
    }
}
