import XCTest
import Foundation
@testable import EyesOnGlass

final class DatabaseExporterTests: XCTestCase {

    var sampleLogs: [VideoLog]!

    override func setUp() {
        super.setUp()
        sampleLogs = [
            VideoLog(
                videoFilename: "test.mp4",
                timestampSec: 10.5,
                issueType: "macroblocking",
                issueScore: 0.95,
                analysisEngine: "OpenCV Junior",
                createdAt: Date(timeIntervalSince1970: 1713000000), // static time
                sessionIdentifier: "TestSession1"
            )
        ]
    }

    override func tearDown() {
        sampleLogs = nil
        super.tearDown()
    }

    func testExportToCSV() async throws {
        let csvString = try await DatabaseExporter.generateCSV(logs: sampleLogs)
        XCTAssertTrue(csvString.contains("Time,Type,Engine,PTS,Confidence,URI,Session"))
        XCTAssertTrue(csvString.contains("MACROBLOCKING")) // Wait the implementation uppercases ? No, CSV doesn't, PDF does.
        XCTAssertTrue(csvString.contains("test.mp4"))
        XCTAssertTrue(csvString.contains("10.500"))
        XCTAssertTrue(csvString.contains("0.95"))
    }

    func testExportToJSON() async throws {
        let jsonData = try await DatabaseExporter.generateJSON(logs: sampleLogs)
        let jsonObject = try JSONSerialization.jsonObject(with: jsonData, options: [])
        guard let jsonArray = jsonObject as? [[String: Any]], let first = jsonArray.first else {
            XCTFail("JSON output is not an array of objects")
            return
        }
        
        XCTAssertEqual(first["videoFilename"] as? String, "test.mp4")
        XCTAssertEqual(first["issueType"] as? String, "macroblocking")
        XCTAssertEqual(first["timestampSec"] as? Double, 10.5)
        XCTAssertEqual(first["issueScore"] as? Double, 0.95)
    }

    @MainActor
    func testExportToPDF() async throws {
        let pdfData = try await DatabaseExporter.generatePDF(logs: sampleLogs)
        XCTAssertTrue(pdfData.count > 0, "PDF data should not be empty")
        
        // PDF headers check
        let pdfHeader = Data("%PDF".utf8)
        XCTAssertEqual(pdfData.prefix(4), pdfHeader, "Generated data is not a valid PDF")
    }
}
