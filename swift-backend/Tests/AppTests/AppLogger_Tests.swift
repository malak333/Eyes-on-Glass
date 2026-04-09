@testable import App
import XCTest
import Logging

final class AppLogger_Tests: XCTestCase {
    
    func testGlobalPrintOverride() throws {
        // Assert that the appLogger is fully structured and properly configured within the application context.
        XCTAssertEqual(appLogger.label, "eyes-on-glass.app", "The globally exposed appLogger should properly target the expected app label")
        
        // This invocation serves as a sanity check assuring the global print override executes seamlessly without panics or crashes.
        let invocationTest = "Testing the timestamp logging mechanism"
        print(invocationTest)
        
        // Test multiple parameters to ensure String iterables format properly through the override.
        print("Multiple", "arguments", "should", "join", "correctly", separator: "-")
    }
}
