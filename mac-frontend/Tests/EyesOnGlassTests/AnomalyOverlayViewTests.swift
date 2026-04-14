import XCTest
import SwiftUI
@testable import EyesOnGlass

final class AnomalyOverlayViewTests: XCTestCase {
    
    func testOverlayViewValidJSON() {
        let validJSON = "[[0.1, 0.2, 0.05, 0.05], [0.5, 0.5, 0.1, 0.1]]"
        let view = AnomalyOverlayView(boundingBoxesJSON: validJSON)
        let boxes = view.boundingBoxes
        
        XCTAssertEqual(boxes.count, 2)
        XCTAssertEqual(boxes[0].origin.x, 0.1)
        XCTAssertEqual(boxes[1].size.width, 0.1)
    }
    
    func testOverlayViewInvalidJSON() {
        let view = AnomalyOverlayView(boundingBoxesJSON: "invalid json string")
        let boxes = view.boundingBoxes
        XCTAssertTrue(boxes.isEmpty)
    }
    
    func testOverlayViewPartialOrMalformedJSON() {
        // Includes an array with only 3 elements (invalid bounding box)
        let malformedJSON = "[[0.1, 0.2, 0.05], [0.5, 0.5, 0.1, 0.1]]"
        let view = AnomalyOverlayView(boundingBoxesJSON: malformedJSON)
        let boxes = view.boundingBoxes
        
        XCTAssertEqual(boxes.count, 1) // Only one valid box
        XCTAssertEqual(boxes[0].origin.x, 0.5)
    }
    
    func testOverlayViewNilJSON() {
        let view = AnomalyOverlayView(boundingBoxesJSON: nil)
        XCTAssertTrue(view.boundingBoxes.isEmpty)
    }
}
