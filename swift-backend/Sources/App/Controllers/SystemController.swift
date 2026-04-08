import Vapor

struct SystemController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let system = routes.grouped("system")
        system.get("resources", use: getResources)
        system.get("ollama_status", use: checkOllama)
    }
    
    @Sendable
    func getResources(req: Request) async throws -> [String: [SystemMonitor.StatPoint]] {
        return await SystemMonitor.shared.getAggregatedStats()
    }
    
    @Sendable
    func checkOllama(req: Request) async throws -> [String: String] {
        do {
            let res = try await req.client.get("http://localhost:11434/")
            if res.status == .ok {
                return ["status": "running"]
            }
        } catch {
            return ["status": "stopped"]
        }
        return ["status": "stopped"]
    }
}
