import SwiftUI

struct AnomalyOverlayView: View {
    let boundingBoxesJSON: String?
    
    var boundingBoxes: [CGRect] {
        guard let jsonStr = boundingBoxesJSON,
              let data = jsonStr.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[CGFloat]] else {
            return []
        }
        
        return array.compactMap { boxArray in
            guard boxArray.count == 4 else { return nil }
            return CGRect(x: boxArray[0], y: boxArray[1], width: boxArray[2], height: boxArray[3])
        }
    }
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                ForEach(Array(boundingBoxes.enumerated()), id: \.offset) { index, box in
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.red.opacity(0.8), lineWidth: 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.red.opacity(0.2))
                        )
                        .shadow(color: .red, radius: 4, x: 0, y: 0)
                        .frame(
                            width: box.width * geometry.size.width,
                            height: box.height * geometry.size.height
                        )
                        .position(
                            x: (box.origin.x + box.width / 2) * geometry.size.width,
                            y: (box.origin.y + box.height / 2) * geometry.size.height
                        )
                }
            }
        }
        .allowsHitTesting(false)
    }
}
