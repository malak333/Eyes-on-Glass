import Vapor
import Fluent
import FluentSQLiteDriver

public func configure(_ app: Application) async throws {
    // Configure CORS
    let corsConfiguration = CORSMiddleware.Configuration(
        allowedOrigin: .all,
        allowedMethods: [.GET, .POST, .PUT, .OPTIONS, .DELETE, .PATCH],
        allowedHeaders: [.accept, .authorization, .contentType, .origin, .xRequestedWith, .userAgent, .accessControlAllowOrigin]
    )
    let cors = CORSMiddleware(configuration: corsConfiguration)
    app.middleware.use(cors, at: .beginning)

    // Allows serving static files from Public directories, we will set up 'thumbnails'
    // in routes.swift using req.fileio.streamFile instead to avoid FileMiddleware path appending issues.
    
    // Increase maximum body size for video uploads
    app.routes.defaultMaxBodySize = "1gb"
    
    // Configure SQLite Database
    // Point it directly to the existing sqlite.db in the backend folder
    let dbPath = app.directory.workingDirectory + "../backend/sqlite.db"
    app.databases.use(.sqlite(.file(dbPath)), as: .sqlite)

    // register routes
    try routes(app)
    
    // start background system telemetry
    await SystemMonitor.shared.start()
}
