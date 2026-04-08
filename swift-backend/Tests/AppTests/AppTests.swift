@testable import App
import XCTVapor

final class AppTests: XCTestCase {
    func testCORSHeadersArePresent() async throws {
        let app = Application(.testing)
        defer { app.shutdown() }
        try await configure(app)

        try app.test(.OPTIONS, "upload", beforeRequest: { req in
            req.headers.add(name: "Origin", value: "http://localhost:5173")
            req.headers.add(name: "Access-Control-Request-Method", value: "POST")
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .ok)
            XCTAssertTrue(res.headers.contains(name: "access-control-allow-origin"))
            XCTAssertEqual(res.headers.first(name: "access-control-allow-origin"), "*")
            XCTAssertTrue(res.headers.contains(name: "access-control-allow-methods"))
        })
    }
}
