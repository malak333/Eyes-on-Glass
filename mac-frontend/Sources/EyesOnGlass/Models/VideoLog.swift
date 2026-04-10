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

    init(videoFilename: String = "",
         timestampSec: Double = 0.0,
         nodeSource: String? = nil,
         nodeBackbone: String? = nil,
         nodeDest: String? = nil,
         issueType: String = "",
         issueScore: Double? = nil,
         analysisEngine: String? = nil,
         thumbnailPath: String? = nil,
         createdAt: Date = Date()) {
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
    }
}
