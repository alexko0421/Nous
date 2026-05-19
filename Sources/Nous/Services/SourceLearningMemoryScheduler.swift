import Foundation

actor SourceLearningMemoryScheduler {
    private let service: SourceLearningMemoryService
    private static let maxReplayedActivityEvents = 20
    private var activityHandler: (@Sendable (MemoryActivityEvent) async -> Void)?
    private var latestActivityEventsByConversation: [UUID: MemoryActivityEvent] = [:]
    private var activityReplayOrder: [UUID] = []
    private struct ScheduledTask {
        let token: UUID
        let task: Task<Void, Never>
    }

    private var conversationTails: [UUID: ScheduledTask] = [:]
    private var scheduledTasks: [UUID: Task<Void, Never>] = [:]

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
        let previous = conversationTails[request.conversationId]?.task
        let token = UUID()
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
            await self?.finish(conversationId: request.conversationId, token: token)
        }
        conversationTails[request.conversationId] = ScheduledTask(token: token, task: task)
        scheduledTasks[token] = task
    }

    func waitUntilIdle() async {
        let tasks = Array(scheduledTasks.values)
        for task in tasks {
            await task.value
        }
    }

    func debugRetainedTaskCounts() -> (conversationTails: Int, scheduledTasks: Int, latestActivityEvents: Int) {
        (conversationTails.count, scheduledTasks.count, latestActivityEventsByConversation.count)
    }

    private func recordActivity(_ event: MemoryActivityEvent) async {
        if latestActivityEventsByConversation[event.conversationId] == nil {
            activityReplayOrder.append(event.conversationId)
        }
        latestActivityEventsByConversation[event.conversationId] = event
        while activityReplayOrder.count > Self.maxReplayedActivityEvents {
            let expiredConversationId = activityReplayOrder.removeFirst()
            latestActivityEventsByConversation[expiredConversationId] = nil
        }
        if let activityHandler {
            await activityHandler(event)
        }
    }

    private func finish(conversationId: UUID, token: UUID) {
        if conversationTails[conversationId]?.token == token {
            conversationTails[conversationId] = nil
        }
        scheduledTasks[token] = nil
    }
}
