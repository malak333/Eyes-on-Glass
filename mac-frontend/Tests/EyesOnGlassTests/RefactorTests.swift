import XCTest
@testable import EyesOnGlass

final class RefactorTests: XCTestCase {

    func testBitrateCalculator() {
        let calculator = BitrateCalculator()

        // Test initial state
        let result1 = calculator.update(delta: 1000, elapsed: 1.0)
        XCTAssertFalse(result1.isVBR)

        // Test VBR detection (needs at least 5 points)
        _ = calculator.update(delta: 100, elapsed: 1.0)
        _ = calculator.update(delta: 1000, elapsed: 1.0)
        _ = calculator.update(delta: 100, elapsed: 1.0)
        _ = calculator.update(delta: 1000, elapsed: 1.0)
        let resultVBR = calculator.update(delta: 100, elapsed: 1.0)
        XCTAssertTrue(resultVBR.isVBR)

        calculator.reset()
        let resultReset = calculator.update(delta: 1000, elapsed: 1.0)
        XCTAssertFalse(resultReset.isVBR)
    }

    func testStreamMetadata() {
        var metadata = StreamMetadata()
        XCTAssertNil(metadata.videoPID)

        metadata.videoPID = 100
        XCTAssertEqual(metadata.videoPID, 100)
    }
}
