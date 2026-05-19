import Foundation

actor SourceLearningMemoryScheduler {
    private let service: SourceLearningMemoryService
    private var activityHandler: (@Sendable (MemoryActivityEvent) async -> Void)?
    private var latestActivityEventsByConversation: [UUID: MemoryActivityEvent] = [:]
    private var conversationTails: [UUID: Task<Void, Never>] = [:]
    private var scheduledTasks: [Task<Void, Never>] = []

    init(service: SourceLearningMemoryService) {
        self.service = service
    }

    func setActivityHandler(_ handler: (@Sendable (MemoryActivityEvent) async -> Void)?) async {
        activityHandler = handler
        guard let handler else { return }
        for event in latestActivityEventsByConversation.values {
            await handler(event)
        }
    }

    func enqueue(_ request: SourceLearningDigestRequest) {
        let previous = conversationTails[request.conversationId]
        let task = Task { [service, weak self] in
            if let previous {
                await previous.value
            }
            let result = await service.absorb(request)
            await self?.recordActivity(MemoryActivityEvent(
                source: .sourceLearning,
                turnId: request.turnId,
                conversationId: request.conversationId,
                activeCount: result.activeCount,
                pendingCount: result.pendingCount,
                rejectedCount: result.rejectedCount,
                recordedAt: Date()
            ))
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

    private func recordActivity(_ event: MemoryActivityEvent) async {
        latestActivityEventsByConversation[event.conversationId] = event
        if let activityHandler {
            await activityHandler(event)
        }
    }
}
