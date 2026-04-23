import Foundation
import Observation

/// Per-conversation scratchpad state. The store caches these in memory and persists
/// them to UserDefaults keyed by the conversation's UUID.
private struct ConversationScratchState: Equatable {
    var latestSummary: ScratchSummary?
    var currentContent: String
    var baseSnapshot: String
    var contentBaseGeneratedAt: Date?
    var pendingOverwrite: ScratchSummary?

    static let empty = ConversationScratchState(
        latestSummary: nil,
        currentContent: "",
        baseSnapshot: "",
        contentBaseGeneratedAt: nil,
        pendingOverwrite: nil
    )
}

/// Owns the ScratchPad panel's state, scoped per conversation.
///
/// The observable fields (`latestSummary`, `currentContent`, `baseSnapshot`,
/// `contentBaseGeneratedAt`, `pendingOverwrite`) always mirror the **active
/// conversation's** state. Call `activate(conversationId:)` whenever the chat
/// view switches conversations (including to `nil` when no conversation is
/// loaded). State for inactive conversations is preserved in an in-memory cache
/// plus UserDefaults, so switching back restores what was there.
///
/// `isDirty` is derived (`currentContent != baseSnapshot`) and drives the "•"
/// in the panel header. `pendingOverwrite` is set only when a newer summary has
/// arrived but the user has unsaved edits; UI must show a confirm alert and
/// then call `acceptPendingOverwrite()` or `rejectPendingOverwrite()`.
@Observable
@MainActor
final class ScratchPadStore {

    // MARK: - Public state (observable, mirrors active conversation)

    private(set) var latestSummary: ScratchSummary?
    private(set) var currentContent: String
    private(set) var baseSnapshot: String
    private(set) var contentBaseGeneratedAt: Date?
    private(set) var pendingOverwrite: ScratchSummary?
    private(set) var activeConversationId: UUID?

    var isDirty: Bool { currentContent != baseSnapshot }

    // MARK: - Storage

    private let defaults: UserDefaults
    private var loadedStates: [UUID: ConversationScratchState] = [:]

    private enum Keys {
        static let conversationPrefix = "nous.scratchpad.conv."

        // Legacy app-level keys from the pre-per-conversation version. Deleted on init.
        static let legacyLatest = "nous.scratchpad.latestSummary"
        static let legacyContent = "nous.scratchpad.content"
        static let legacyBase = "nous.scratchpad.baseSnapshot"
        static let legacyBaseDate = "nous.scratchpad.contentBaseDate"

        static func latestSummary(_ id: UUID) -> String { "\(conversationPrefix)\(id.uuidString).latestSummary" }
        static func content(_ id: UUID) -> String { "\(conversationPrefix)\(id.uuidString).content" }
        static func base(_ id: UUID) -> String { "\(conversationPrefix)\(id.uuidString).base" }
        static func baseDate(_ id: UUID) -> String { "\(conversationPrefix)\(id.uuidString).baseDate" }
    }

    // MARK: - Init

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.latestSummary = nil
        self.currentContent = ""
        self.baseSnapshot = ""
        self.contentBaseGeneratedAt = nil
        self.pendingOverwrite = nil
        self.activeConversationId = nil

        // Drop legacy app-level state: we can't attribute it to a specific conversation,
        // so per-conversation state will rebuild from the next summary onward.
        defaults.removeObject(forKey: Keys.legacyLatest)
        defaults.removeObject(forKey: Keys.legacyContent)
        defaults.removeObject(forKey: Keys.legacyBase)
        defaults.removeObject(forKey: Keys.legacyBaseDate)
    }

    // MARK: - Activation (conversation switch)

    /// Swap the observable state to the given conversation. Pass `nil` when no
    /// conversation is loaded (e.g., the chat tab opens with no selected chat).
    /// Current in-memory state for the previously-active conversation is
    /// preserved in the cache; it will be restored verbatim on the next
    /// `activate(conversationId:)` call for that id.
    func activate(conversationId: UUID?) {
        if let previousId = activeConversationId {
            loadedStates[previousId] = currentActiveState
        }

        activeConversationId = conversationId

        guard let newId = conversationId else {
            apply(state: .empty)
            return
        }

        let state = loadedStates[newId] ?? load(conversationId: newId)
        loadedStates[newId] = state
        apply(state: state)
    }

    // MARK: - Ingest (ChatViewModel → store)

    /// Called after an assistant reply is finalized. If the text contains a
    /// well-formed <summary> tag, captures it as the latest summary for the
    /// given conversation. No-ops otherwise.
    ///
    /// `conversationId` should be the conversation that produced the reply. If
    /// omitted, the currently-active conversation is used.
    func ingestAssistantMessage(
        content: String,
        sourceMessageId: UUID,
        conversationId: UUID? = nil,
        now: Date = Date()
    ) {
        guard let markdown = ClarificationCardParser.extractSummary(from: content) else {
            return
        }
        let summary = ScratchSummary(
            markdown: markdown,
            generatedAt: now,
            sourceMessageId: sourceMessageId
        )
        ingest(summary: summary, conversationId: conversationId)
    }

    /// Lower-level ingestion used by tests and by `ingestAssistantMessage`.
    /// If `conversationId` is nil, the active conversation is used.
    func ingest(summary: ScratchSummary, conversationId: UUID? = nil) {
        let targetId = conversationId ?? activeConversationId
        guard let targetId else { return }

        let isActive = targetId == activeConversationId
        var state = isActive
            ? currentActiveState
            : (loadedStates[targetId] ?? load(conversationId: targetId))

        // Skip duplicate-content summaries so the panel doesn't flash a spurious
        // overwrite alert when the LLM emits the same <summary> block twice in a row.
        if state.latestSummary?.markdown == summary.markdown {
            return
        }

        state.latestSummary = summary
        loadedStates[targetId] = state
        persistLatestSummary(summary, for: targetId)

        if isActive {
            latestSummary = summary
        }
    }

    // MARK: - Panel lifecycle (operates on active conversation)

    /// Called when the panel becomes visible OR when `latestSummary` changes
    /// while the panel is already visible. Implements the load logic from §6
    /// of the spec.
    func onPanelOpened() {
        guard activeConversationId != nil, let latest = latestSummary else {
            return
        }

        if let base = contentBaseGeneratedAt, base == latest.generatedAt {
            return
        }

        let hasUserContent = contentBaseGeneratedAt == nil && !currentContent.isEmpty

        if !isDirty && !hasUserContent {
            applyOverwrite(to: latest)
            return
        }

        pendingOverwrite = latest
    }

    func acceptPendingOverwrite() {
        guard let next = pendingOverwrite else { return }
        applyOverwrite(to: next)
        pendingOverwrite = nil
    }

    func rejectPendingOverwrite() {
        pendingOverwrite = nil
    }

    // MARK: - Edits (active conversation)

    func updateContent(_ newValue: String) {
        guard let activeId = activeConversationId else { return }
        currentContent = newValue
        defaults.set(newValue, forKey: Keys.content(activeId))

        // Free-typing in empty state: keep base glued to content so isDirty stays
        // false until the first summary lands.
        if latestSummary == nil && contentBaseGeneratedAt == nil {
            baseSnapshot = newValue
            defaults.set(newValue, forKey: Keys.base(activeId))
        }
    }

    /// Called by the panel after NSSavePanel completes successfully. The on-disk
    /// file becomes the new clean baseline; `contentBaseGeneratedAt` is left
    /// untouched so a newer summary still counts as "newer than what's shown".
    func markDownloaded() {
        guard let activeId = activeConversationId else { return }
        baseSnapshot = currentContent
        defaults.set(currentContent, forKey: Keys.base(activeId))
    }

    // MARK: - Helpers

    private var currentActiveState: ConversationScratchState {
        ConversationScratchState(
            latestSummary: latestSummary,
            currentContent: currentContent,
            baseSnapshot: baseSnapshot,
            contentBaseGeneratedAt: contentBaseGeneratedAt,
            pendingOverwrite: pendingOverwrite
        )
    }

    private func apply(state: ConversationScratchState) {
        latestSummary = state.latestSummary
        currentContent = state.currentContent
        baseSnapshot = state.baseSnapshot
        contentBaseGeneratedAt = state.contentBaseGeneratedAt
        pendingOverwrite = state.pendingOverwrite
    }

    private func applyOverwrite(to summary: ScratchSummary) {
        guard let activeId = activeConversationId else { return }
        currentContent = summary.markdown
        baseSnapshot = summary.markdown
        contentBaseGeneratedAt = summary.generatedAt
        defaults.set(summary.markdown, forKey: Keys.content(activeId))
        defaults.set(summary.markdown, forKey: Keys.base(activeId))
        defaults.set(summary.generatedAt.timeIntervalSince1970, forKey: Keys.baseDate(activeId))
    }

    private func load(conversationId: UUID) -> ConversationScratchState {
        let latest: ScratchSummary?
        if let data = defaults.data(forKey: Keys.latestSummary(conversationId)),
           let decoded = try? JSONDecoder().decode(ScratchSummary.self, from: data) {
            latest = decoded
        } else {
            latest = nil
        }

        let content = defaults.string(forKey: Keys.content(conversationId)) ?? ""
        let base = defaults.string(forKey: Keys.base(conversationId)) ?? ""

        let baseDate: Date?
        if let raw = defaults.object(forKey: Keys.baseDate(conversationId)) as? Double {
            baseDate = Date(timeIntervalSince1970: raw)
        } else {
            baseDate = nil
        }

        return ConversationScratchState(
            latestSummary: latest,
            currentContent: content,
            baseSnapshot: base,
            contentBaseGeneratedAt: baseDate,
            pendingOverwrite: nil
        )
    }

    private func persistLatestSummary(_ summary: ScratchSummary, for conversationId: UUID) {
        if let data = try? JSONEncoder().encode(summary) {
            defaults.set(data, forKey: Keys.latestSummary(conversationId))
        }
    }
}
