import Foundation

actor SourceLearningMemoryScheduler {
    private let service: SourceLearningMemoryService
    private var activityHandler: (@Sendable (MemoryActivityEvent) async -> Void)?
    private var conversationTails: [UUID: Task<Void, Never>] = [:]
    private var scheduledTasks: [Task<Void, Never>] = []

    init(service: SourceLearningMemoryService) {
        self.service = service
    }

    func setActivityHandler(_ handler: (@Sendable (MemoryActivityEvent) async -> Void)?) {
        activityHandler = handler
    }

    func enqueue(_ request: SourceLearningDigestRequest) {
        let previous = conversationTails[request.conversationId]
        let activityHandler = activityHandler
        let task = Task { [service] in
            if let previous {
                await previous.value
            }
            let result = await service.absorb(request)
            if let activityHandler {
                await activityHandler(MemoryActivityEvent(
                    source: .sourceLearning,
                    turnId: request.turnId,
                    conversationId: request.conversationId,
                    activeCount: result.activeCount,
                    pendingCount: result.pendingCount,
                    rejectedCount: result.rejectedCount,
                    recordedAt: Date()
                ))
            }
        }
        conversationTails[request.conversationId] = task
        scheduledTasks.append(task)
    }

    func waitUntilIdle() async {
        let tasks = scheduledTasks
        scheduledTasks = []
        for task in tasks {
            await task.value
        }
    }
}
