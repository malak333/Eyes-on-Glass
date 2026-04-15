import XCTest
import CoreImage
@testable import EyesOnGlass

final class SpatialDensityFilterTests: XCTestCase {
    
    func testMacroblockingDensityGate() {
        // High confidence, high variance, but only 2 grid corruptions (False Positive)
        var metricsFP = ValidationMetrics(
            meanBrightness: 50.0,
            isBlackScreen: false,
            laplacianVariance: 25.0,
            isBlurry: false,
            blockiness: 1.35,
            macroConfidence: 0.20,
            hasTopArtifact: false,
            isBars: false,
            isSnowflakes: false,
            anomalyBoundingBoxes: [
                CGRect(x: 0, y: 0, width: 32, height: 32),
                CGRect(x: 32, y: 0, width: 32, height: 32)
            ]
        )
        
        XCTAssertFalse(metricsFP.isDefinitivelyMacroblocked, "Should suppress macroblocking if spatial density rule (< 3 blocks) is not met.")
        
        // Proper widespread macroblocking (True Positive)
        var metricsTP = metricsFP
        metricsTP.anomalyBoundingBoxes.append(CGRect(x: 64, y: 0, width: 32, height: 32))
        
        XCTAssertTrue(metricsTP.isDefinitivelyMacroblocked, "Should confirm macroblocking if spatial density rule (>= 3 blocks) is met.")
        
        // Low variance suppression
        metricsTP.laplacianVariance = 10.0
        XCTAssertFalse(metricsTP.isDefinitivelyMacroblocked, "Should suppress macroblocking if scene complexity is too low.")
        
        // Low confidence suppression
        metricsTP.laplacianVariance = 25.0
        metricsTP.macroConfidence = 0.10
        XCTAssertFalse(metricsTP.isDefinitivelyMacroblocked, "Should suppress macroblocking if baseline math confidence is below 0.15.")
    }
}
