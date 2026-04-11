import XCTest
import SwiftUI
@testable import EyesOnGlass

final class AdvancedInspectorGridsTests: XCTestCase {
    
    // Testing the basic instantiation of our new Grid Overlay views
    // to ensure they satisfy structural requirements and don't cause runtime view-hierarchy fatal errors.

    func testVerticalScaleOverlayInstantiation() {
        let view = VerticalScaleOverlay(topLabel: "+1.0", bottomLabel: "-1.0")
        XCTAssertNotNil(view.body)
        
        let mirror = Mirror(reflecting: view)
        XCTAssertEqual(mirror.children.count, 2) // Reflecting topLabel and bottomLabel properties
    }
    
    func testAudioDecibelGridOverlayInstantiation() {
        let view = AudioDecibelGridOverlay()
        XCTAssertNotNil(view.body)
    }
    
    func testVectorscopeGridOverlayInstantiation() {
        let view = VectorscopeGridOverlay()
        XCTAssertNotNil(view.body)
    }
}
