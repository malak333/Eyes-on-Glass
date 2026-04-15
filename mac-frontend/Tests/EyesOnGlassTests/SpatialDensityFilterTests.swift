import XCTest
import CoreImage
@testable import EyesOnGlass

final class SpatialDensityFilterTests: XCTestCase {
    
    func testMacroblockingDensityGate() {
        // High variance, but only 3 grid corruptions (False Positive under new rules)
        var metricsFP = ValidationMetrics(
            meanBrightness: 50.0,
            isBlackScreen: false,
            laplacianVariance: 25.0,
            isBlurry: false,
            blockiness: 1.45,
            macroConfidence: 0.40,
            hasTopArtifact: false,
            isBars: false,
            isSnowflakes: false,
            anomalyBoundingBoxes: [
                CGRect(x: 0, y: 0, width: 32, height: 32),
                CGRect(x: 32, y: 0, width: 32, height: 32),
                CGRect(x: 64, y: 0, width: 32, height: 32)
            ],
            isGraphic: false
        )
        
        XCTAssertFalse(metricsFP.isDefinitivelyMacroblocked, "Should suppress macroblocking if spatial density rule (< 4 blocks) is not met.")
        
        // Proper widespread macroblocking (True Positive)
        var metricsTP = metricsFP
        metricsTP.anomalyBoundingBoxes.append(CGRect(x: 96, y: 0, width: 32, height: 32)) // 4th box
        
        XCTAssertTrue(metricsTP.isDefinitivelyMacroblocked, "Should confirm macroblocking if spatial density rule (>= 4 blocks) is met.")
        
        // Dark scene suppression (fade to black causing compression artifacts)
        metricsTP.meanBrightness = 20.0
        XCTAssertFalse(metricsTP.isDefinitivelyMacroblocked, "Should suppress macroblocking if the scene is determined exactly too dark (< 25.0) which boosts codec jitter.")
        
        // Low confidence suppression
        metricsTP.meanBrightness = 50.0
        metricsTP.macroConfidence = 0.30
        XCTAssertFalse(metricsTP.isDefinitivelyMacroblocked, "Should suppress macroblocking if baseline math confidence is below 0.35.")
        
        // Graphic override test
        metricsTP.macroConfidence = 0.40
        metricsTP.isGraphic = true
        XCTAssertFalse(metricsTP.isDefinitivelyMacroblocked, "Should respect graphic gate for a normal slate if blockiness is <= 4.0.")
        
        // Severe macro override (ignores graphic gate)
        metricsTP.blockiness = 4.5
        XCTAssertTrue(metricsTP.isDefinitivelyMacroblocked, "Should override graphic gate and flag if signal is exceptionally destructive (blockiness > 4.0).")
    }
}
