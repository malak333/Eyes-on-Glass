import XCTest
import SwiftUI
@testable import EyesOnGlass

final class AudioBarsViewTests: XCTestCase {
    
    // Testing the basic instantiation of AudioBarsView with boundary variables
    // to ensure safe bounds when referencing up to 16 channels.

    @MainActor
    func testAudioBarsViewZeroChannels() {
        let view = AudioBarsView(audioLevels: [])
        XCTAssertNotNil(view.body)
        XCTAssertEqual(view.audioLevels.count, 0)
    }

    @MainActor
    func testAudioBarsViewStereoChannels() {
        let view = AudioBarsView(audioLevels: [0.5, 0.6])
        XCTAssertNotNil(view.body)
        XCTAssertEqual(view.audioLevels.count, 2)
    }
    
    @MainActor
    func testAudioBarsView16Channels() {
        let levels = Array(repeating: Float(0.5), count: 16)
        let view = AudioBarsView(audioLevels: levels)
        XCTAssertNotNil(view.body)
        XCTAssertEqual(view.audioLevels.count, 16)
    }

    @MainActor
    func testAudioBarsViewMoreThan16Channels() {
        let levels = Array(repeating: Float(0.8), count: 24)
        let view = AudioBarsView(audioLevels: levels)
        XCTAssertNotNil(view.body)
        XCTAssertEqual(view.audioLevels.count, 24)
        // Canvas rendering implicitly limits indices out-of-bounds in the logic 
        // using count=16 and min(newVal.count, 16). The body access shouldn't trap.
    }
}
