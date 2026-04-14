import Foundation
import SwiftData

@Model
final class VideoLog {


    var videoFilename: String
    var timestampSec: Double
    var nodeSource: String?
    var nodeBackbone: String?
    var nodeDest: String?
    var issueType: String
    var issueScore: Double?
    var analysisEngine: String?
    var thumbnailPath: String?
    var createdAt: Date
    var isArchived: Bool = false
    var sessionIdentifier: String?
    var sessionStartTime: Date?
    var issueSummary: String?

    init(videoFilename: String = "",
         timestampSec: Double = 0.0,
         nodeSource: String? = nil,
         nodeBackbone: String? = nil,
         nodeDest: String? = nil,
         issueType: String = "",
         issueScore: Double? = nil,
         analysisEngine: String? = nil,
         thumbnailPath: String? = nil,
         createdAt: Date = Date(),
         isArchived: Bool = false,
         sessionIdentifier: String? = nil,
         sessionStartTime: Date? = nil,
         issueSummary: String? = nil) {
        self.videoFilename = videoFilename
        self.timestampSec = timestampSec
        self.nodeSource = nodeSource
        self.nodeBackbone = nodeBackbone
        self.nodeDest = nodeDest
        self.issueType = issueType
        self.issueScore = issueScore
        self.analysisEngine = analysisEngine
        self.thumbnailPath = thumbnailPath
        self.createdAt = createdAt
        self.isArchived = isArchived
        self.sessionIdentifier = sessionIdentifier
        self.sessionStartTime = sessionStartTime
        self.issueSummary = issueSummary
    }
}
