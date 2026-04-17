import Foundation
import SwiftData

/// A repository for managing VideoLog operations, decoupling the controller from direct ModelContext interactions.
@MainActor
final class VideoLogRepository {
    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    func insert(log: VideoLog) {
        modelContext.insert(log)
    }

    func fetchActiveLogs() -> [VideoLog] {
        let descriptor = FetchDescriptor<VideoLog>(predicate: #Predicate { $0.isArchived == false })
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    func archiveLogs(_ logs: [VideoLog]) {
        for log in logs {
            log.isArchived = true
        }
    }

    func save() {
        try? modelContext.save()
    }
}
