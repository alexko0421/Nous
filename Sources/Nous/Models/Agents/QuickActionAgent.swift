import Foundation

/// Per-mode runtime contract for quick actions. Each agent owns:
/// - the opening prompt text sent on the synthetic turn-0 invocation
/// - per-turn volatile context addenda
/// - a memory access policy that quick-action and turn planning consult to gate
///   memory fetches
/// - a per-turn directive that drives whether activeQuickActionMode is preserved
///
/// Voice (anchor.md) is NOT owned by the agent; it stays in the shared stable layer
/// of `PromptContextAssembler.assembleContext`. Agents only contribute to volatile.
///
/// QuickActionAgent is a context-policy struct, not a runtime agent. A turn runs as
/// one continuous LLM call sharing anchor, transcript, and memory — no per-mode
/// handoff. Any future change that spawns a second LLM call inside a turn must
/// justify itself as a context boundary, never as a role split
/// (planner / implementer / verifier) — role splits drop context at every handoff.
protocol QuickActionAgent {
    var mode: QuickActionMode { get }

    /// Called once when the user taps the quick-action chip.
    func openingPrompt() -> String

    /// Called every turn while activeQuickActionMode == self.mode.
    /// Returns a volatile context block to append after the ACTIVE QUICK MODE marker.
    /// turnIndex is the user-message count in the conversation (0 on the synthetic
    /// opening turn before any user reply, 1 after the first user reply, ...).
    /// Returning nil means "no addendum on this turn".
    func contextAddendum(turnIndex: Int) -> String?

    /// Memory access policy. Resolved once per turn before any memory fetching.
    /// The dispatcher gates each memory fetch / injection on the corresponding
    /// policy bool.
    func memoryPolicy() -> QuickActionMemoryPolicy

    var toolNames: [String] { get }
    var useAgentLoop: Bool { get }

    /// Per-turn directive. Resolved after `ClarificationCardParser` parses the
    /// assistant response. Drives whether activeQuickActionMode is preserved
    /// for the next turn or dropped.
    func turnDirective(
        parsed: ClarificationContent,
        turnIndex: Int
    ) -> QuickActionTurnDirective
}

extension QuickActionAgent {
    var toolNames: [String] { [] }
    var useAgentLoop: Bool { !toolNames.isEmpty }
}

/// 12-bool policy. Each bool maps 1:1 to a memory fetch / injection site:
/// - includeGlobalMemory ↔ MemoryProjectionService.currentGlobal()
/// - includeEssentialStory ↔ MemoryProjectionService.currentEssentialStory(...)
/// - includeUserModel ↔ MemoryProjectionService.currentUserModel(...)
/// - includeMemoryEvidence ↔ MemoryProjectionService.currentBoundedEvidence(...)
/// - includeProjectMemory ↔ MemoryProjectionService.currentProject(...)
/// - includeConversationMemory ↔ MemoryProjectionService.currentConversation(...)
/// - includeRecentConversations ↔ NodeStore.fetchRecentConversationMemories(...)
/// - includeProjectGoal ↔ NodeStore.fetchProject(id:).goal injection
/// - includeCitations ↔ TurnPlanner.retrieveCitations(...)
/// - includeContradictionRecall ↔ graph recall planner + ContradictionMemoryService.contradictionRecallFacts(...)
/// - includeJudgeFocus ↔ provocation judge invocation + focusBlock derivation
/// - includeBehaviorProfile ↔ BehaviorProfile.contextBlock injection
///
/// Safe-combination invariants (current factories `.full`, `.lean`, and
/// `.groundedBrainstorm` respect these):
/// - If includeProjectGoal == false, also set includeUserModel == false —
///   currentGoalModel reads Project.goal and would leak it via the user-model layer.
/// - If includeContradictionRecall == false AND includeJudgeFocus == false,
///   citableEntryPool construction is skipped (it pulls reflection + recency content).
/// - If includeJudgeFocus == false, BehaviorProfile.supportive.contextBlock should
///   also be skipped — its block contains memory-related instructions that contradict
///   a no-memory turn.
///
/// Custom policies that violate these invariants are not used by current agents but
/// the type allows them; document the dependency before mixing-and-matching.
struct QuickActionMemoryPolicy: Equatable {
    let includeGlobalMemory: Bool
    let includeEssentialStory: Bool
    let includeUserModel: Bool
    let includeMemoryEvidence: Bool
    let includeProjectMemory: Bool
    let includeConversationMemory: Bool
    let includeRecentConversations: Bool
    let includeProjectGoal: Bool
    let includeCitations: Bool
    let includeContradictionRecall: Bool
    let includeJudgeFocus: Bool
    let includeBehaviorProfile: Bool

    var includeSlowCognition: Bool {
        includeGlobalMemory ||
            includeEssentialStory ||
            includeUserModel ||
            includeMemoryEvidence ||
            includeProjectMemory ||
            includeConversationMemory ||
            includeRecentConversations ||
            includeProjectGoal ||
            includeCitations ||
            includeContradictionRecall
    }

    static let full = QuickActionMemoryPolicy(
        includeGlobalMemory: true,
        includeEssentialStory: true,
        includeUserModel: true,
        includeMemoryEvidence: true,
        includeProjectMemory: true,
        includeConversationMemory: true,
        includeRecentConversations: true,
        includeProjectGoal: true,
        includeCitations: true,
        includeContradictionRecall: true,
        includeJudgeFocus: true,
        includeBehaviorProfile: true
    )

    static let lean = QuickActionMemoryPolicy(
        includeGlobalMemory: false,
        includeEssentialStory: false,
        includeUserModel: false,
        includeMemoryEvidence: false,
        includeProjectMemory: false,
        includeConversationMemory: false,
        includeRecentConversations: false,
        includeProjectGoal: false,
        includeCitations: false,
        includeContradictionRecall: false,
        includeJudgeFocus: false,
        includeBehaviorProfile: false
    )

    static let groundedBrainstorm = QuickActionMemoryPolicy(
        includeGlobalMemory: true,
        includeEssentialStory: true,
        includeUserModel: true,
        includeMemoryEvidence: true,
        includeProjectMemory: true,
        includeConversationMemory: true,
        includeRecentConversations: true,
        includeProjectGoal: true,
        includeCitations: true,
        includeContradictionRecall: false,
        includeJudgeFocus: false,
        includeBehaviorProfile: true
    )

    func with(
        includeGlobalMemory: Bool? = nil,
        includeEssentialStory: Bool? = nil,
        includeUserModel: Bool? = nil,
        includeMemoryEvidence: Bool? = nil,
        includeProjectMemory: Bool? = nil,
        includeConversationMemory: Bool? = nil,
        includeRecentConversations: Bool? = nil,
        includeProjectGoal: Bool? = nil,
        includeCitations: Bool? = nil,
        includeContradictionRecall: Bool? = nil,
        includeJudgeFocus: Bool? = nil,
        includeBehaviorProfile: Bool? = nil
    ) -> QuickActionMemoryPolicy {
        QuickActionMemoryPolicy(
            includeGlobalMemory: includeGlobalMemory ?? self.includeGlobalMemory,
            includeEssentialStory: includeEssentialStory ?? self.includeEssentialStory,
            includeUserModel: includeUserModel ?? self.includeUserModel,
            includeMemoryEvidence: includeMemoryEvidence ?? self.includeMemoryEvidence,
            includeProjectMemory: includeProjectMemory ?? self.includeProjectMemory,
            includeConversationMemory: includeConversationMemory ?? self.includeConversationMemory,
            includeRecentConversations: includeRecentConversations ?? self.includeRecentConversations,
            includeProjectGoal: includeProjectGoal ?? self.includeProjectGoal,
            includeCitations: includeCitations ?? self.includeCitations,
            includeContradictionRecall: includeContradictionRecall ?? self.includeContradictionRecall,
            includeJudgeFocus: includeJudgeFocus ?? self.includeJudgeFocus,
            includeBehaviorProfile: includeBehaviorProfile ?? self.includeBehaviorProfile
        )
    }

    static func fromStewardPreset(_ preset: TurnMemoryPolicyPreset) -> QuickActionMemoryPolicy {
        switch preset {
        case .full:
            return .full
        case .lean:
            return .lean
        case .projectOnly:
            return QuickActionMemoryPolicy(
                includeGlobalMemory: false,
                includeEssentialStory: false,
                includeUserModel: false,
                includeMemoryEvidence: false,
                includeProjectMemory: true,
                includeConversationMemory: false,
                includeRecentConversations: false,
                includeProjectGoal: true,
                includeCitations: false,
                includeContradictionRecall: false,
                includeJudgeFocus: false,
                includeBehaviorProfile: true
            )
        case .conversationOnly:
            return QuickActionMemoryPolicy(
                includeGlobalMemory: false,
                includeEssentialStory: false,
                includeUserModel: false,
                includeMemoryEvidence: false,
                includeProjectMemory: false,
                includeConversationMemory: true,
                includeRecentConversations: false,
                includeProjectGoal: false,
                includeCitations: false,
                includeContradictionRecall: false,
                includeJudgeFocus: false,
                includeBehaviorProfile: true
            )
        }
    }

    func applyingChallengeStance(_ stance: ChallengeStance) -> QuickActionMemoryPolicy {
        switch stance {
        case .supportFirst, .useSilently:
            return with(
                includeContradictionRecall: false,
                includeJudgeFocus: false
            )
        case .surfaceTension:
            return self
        }
    }

    func applyingJudgePolicy(_ judgePolicy: JudgePolicy) -> QuickActionMemoryPolicy {
        switch judgePolicy {
        case .off:
            return with(
                includeContradictionRecall: false,
                includeJudgeFocus: false
            )
        case .silentFraming:
            return with(
                includeContradictionRecall: true,
                includeJudgeFocus: true
            )
        case .visibleTension:
            return self
        }
    }
}

enum QuickActionTurnDirective: Equatable {
    case keepActive
    case complete
}

extension QuickActionMode {
    func agent() -> any QuickActionAgent {
        switch self {
        case .direction:  return DirectionAgent()
        case .brainstorm: return BrainstormAgent()
        case .plan:       return PlanAgent()
        }
    }
}
