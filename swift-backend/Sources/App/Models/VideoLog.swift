import Fluent
import Vapor

final class VideoLog: Model, @unchecked Sendable {
    static let schema = "video_logs"
    
    @ID(custom: "id", generatedBy: .database)
    var id: Int?

    @Field(key: "video_filename")
    var videoFilename: String

    @Field(key: "timestamp_sec")
    var timestampSec: Double

    @OptionalField(key: "node_source")
    var nodeSource: String?

    @OptionalField(key: "node_backbone")
    var nodeBackbone: String?

    @OptionalField(key: "node_dest")
    var nodeDest: String?

    @Field(key: "issue_type")
    var issueType: String

    @OptionalField(key: "issue_score")
    var issueScore: Double?

    @OptionalField(key: "analysis_engine")
    var analysisEngine: String?

    @OptionalField(key: "thumbnail_path")
    var thumbnailPath: String?

    @Timestamp(key: "created_at", on: .create, format: .iso8601)
    var createdAt: Date?

    init() { }
}
