import SwiftData
import Foundation

@MainActor
final class VideoLogRepository {
    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    func archiveActiveLogs() {
        let descriptor = FetchDescriptor<VideoLog>(predicate: #Predicate { $0.isArchived == false })
        if let activeLogs = try? context.fetch(descriptor) {
            for log in activeLogs {
                log.isArchived = true
            }
            try? context.save()
        }
    }

    func insert(
        videoFilename: String,
        timestampSec: Double,
        nodeSource: String?,
        nodeBackbone: String?,
        nodeDest: String?,
        issueType: String,
        issueScore: Double?,
        analysisEngine: String?,
        thumbnailPath: String?,
        sessionIdentifier: String?,
        sessionStartTime: Date?,
        issueSummary: String? = nil,
        iatMs: Double? = nil,
        boundingBoxes: String? = nil
    ) {
        let log = VideoLog(
            videoFilename: videoFilename,
            timestampSec: timestampSec,
            nodeSource: nodeSource,
            nodeBackbone: nodeBackbone,
            nodeDest: nodeDest,
            issueType: issueType,
            issueScore: issueScore,
            analysisEngine: analysisEngine,
            thumbnailPath: thumbnailPath,
            isArchived: false,
            sessionIdentifier: sessionIdentifier,
            sessionStartTime: sessionStartTime,
            issueSummary: issueSummary,
            iatMs: iatMs,
            boundingBoxes: boundingBoxes
        )
        context.insert(log)
    }
}
