import Vapor

func routes(_ app: Application) throws {
    try app.register(collection: VideoController())
    try app.register(collection: SystemController())
}
