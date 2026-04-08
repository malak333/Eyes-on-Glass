import Vapor
import Fluent
import Foundation

struct VideoController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        // Match FastAPI roots
        routes.on(.POST, "upload", body: .collect(maxSize: "10gb"), use: uploadVideo)
        routes.get("logs", use: getLogs)
        routes.get("stats", use: getStats)
        routes.get("progress", use: getProgress)
    }

    @Sendable
    func uploadVideo(req: Request) async throws -> [String: String] {
        struct Input: Content {
            var file: Vapor.File
        }
        let input = try req.content.decode(Input.self)
        let filename = input.file.filename
        
        let uploadDir = req.application.directory.workingDirectory + "../backend/uploads/"
        let filePath = uploadDir + filename
        try await req.fileio.writeFile(input.file.data, at: filePath)
        
        await ExtractionProgress.shared.set(status: "extracting", current: 0, total: 0, for: filename)
        
        try await VideoLog.query(on: req.db).filter(\.$videoFilename == filename).delete()
            
        req.application.threadPool.submit { _ in
            Task {
                await ExtractionService.extractAndAnalyze(filename: filename, db: req.db, logger: req.logger, client: req.client)
            }
        }
        
        return ["message": "Successfully uploaded \(filename). Processing started."]
    }

    @Sendable
    func getLogs(req: Request) async throws -> [String: [VideoLogResponse]] {
        let logs = try await VideoLog.query(on: req.db).sort(\.$timestampSec, .ascending).all()
        let output = logs.compactMap { log in
            VideoLogResponse(
                id: log.id ?? 0,
                filename: log.videoFilename,
                timestamp_sec: log.timestampSec,
                node_source: log.nodeSource,
                node_backbone: log.nodeBackbone,
                node_dest: log.nodeDest,
                issue_type: log.issueType,
                issue_score: log.issueScore,
                analysis_engine: log.analysisEngine,
                thumbnail_url: log.thumbnailPath != nil ? "/thumbnails/\(log.thumbnailPath!)" : nil,
                created_at: log.createdAt?.ISO8601Format()
            )
        }
        return ["logs": output]
    }
    
    @Sendable
    func getStats(req: Request) async throws -> StatsResponse {
        let logs = try await VideoLog.query(on: req.db).all()
        let totalFrames = logs.count
        if totalFrames == 0 {
            return StatsResponse(total_frames: 0, issues_count: 0, health_score: 100)
        }
        
        let issuesCount = logs.filter { $0.issueType != "ok" }.count
        let healthScore = max(0.0, 100.0 - (Double(issuesCount) / Double(totalFrames) * 100.0))
        
        return StatsResponse(total_frames: totalFrames, issues_count: issuesCount, health_score: healthScore.rounded(toPlaces: 2))
    }

    @Sendable
    func getProgress(req: Request) async throws -> [String: ExtractionProgress.ProgressData] {
        return await ExtractionProgress.shared.all()
    }
}

actor ExtractionProgress {
    static let shared = ExtractionProgress()
    
    struct ProgressData: Content {
        var status: String
        var current: Int
        var total: Int
        var start_time: Double
    }
    
    private var storage: [String: ProgressData] = [:]
    
    func set(status: String, current: Int, total: Int, for filename: String) {
        storage[filename] = ProgressData(status: status, current: current, total: total, start_time: Date().timeIntervalSince1970)
    }
    
    func all() -> [String: ProgressData] {
        return storage
    }
}

struct VideoLogResponse: Content {
    let id: Int
    let filename: String
    let timestamp_sec: Double
    let node_source: String?
    let node_backbone: String?
    let node_dest: String?
    let issue_type: String
    let issue_score: Double?
    let analysis_engine: String?
    let thumbnail_url: String?
    let created_at: String?
}

struct StatsResponse: Content {
    let total_frames: Int
    let issues_count: Int
    let health_score: Double
}

extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let divisor = Foundation.pow(10.0, Double(places))
        return (self * divisor).rounded() / divisor
    }
}
