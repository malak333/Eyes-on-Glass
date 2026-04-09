import Vapor

func routes(_ app: Application) throws {
    // Serve thumbnails explicitly and securely
    app.get("thumbnails", ":filename") { req async throws -> Response in
        let logger = req.logger
        guard let filename = req.parameters.get("filename"),
              !filename.contains("/"),
              !filename.contains("..") else {
            logger.warning("Invalid thumbnail request: bad filename pattern or missing filename")
            throw Abort(.badRequest, reason: "Invalid filename")
        }
        
        let filePath = req.application.directory.workingDirectory + "../backend/thumbnails/" + filename
        
        guard FileManager.default.fileExists(atPath: filePath) else {
            logger.warning("Thumbnail not found at path: \(filePath)")
            throw Abort(.notFound, reason: "Thumbnail not found")
        }
        
        logger.info("Successfully served thumbnail: \(filename)")
        return try await req.fileio.asyncStreamFile(at: filePath)
    }

    try app.register(collection: VideoController())
    try app.register(collection: SystemController())
}
