import Foundation
import Observation

/// Per-conversation scratchpad state. The store caches these in memory and persists
/// them into the main SQLite store keyed by the conversation's UUID.
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
/// plus SQLite, so switching back restores what was there without duplicating
/// scratch content into a second plaintext store.
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

    private let nodeStore: NodeStore
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

    init(nodeStore: NodeStore, defaults: UserDefaults = .standard) {
        self.nodeStore = nodeStore
        self.defaults = defaults
        self.latestSummary = nil
        self.currentContent = ""
        self.baseSnapshot = ""
        self.contentBaseGeneratedAt = nil
        self.pendingOverwrite = nil
        self.activeConversationId = nil

        migrateLegacyDefaultsIfNeeded()
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
            persist(state: currentActiveState, for: previousId)
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
        persist(state: state, for: targetId)

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

        // Free-typing in empty state: keep base glued to content so isDirty stays
        // false until the first summary lands.
        if latestSummary == nil && contentBaseGeneratedAt == nil {
            baseSnapshot = newValue
        }
        loadedStates[activeId] = currentActiveState
        persist(state: currentActiveState, for: activeId)
    }

    /// Called by the panel after NSSavePanel completes successfully. The on-disk
    /// file becomes the new clean baseline; `contentBaseGeneratedAt` is left
    /// untouched so a newer summary still counts as "newer than what's shown".
    func markDownloaded() {
        guard let activeId = activeConversationId else { return }
        baseSnapshot = currentContent
        loadedStates[activeId] = currentActiveState
        persist(state: currentActiveState, for: activeId)
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
        loadedStates[activeId] = currentActiveState
        persist(state: currentActiveState, for: activeId)
    }

    private func load(conversationId: UUID) -> ConversationScratchState {
        guard let record = try? nodeStore.fetchScratchPadState(nodeId: conversationId) else {
            return .empty
        }
        return ConversationScratchState(
            latestSummary: record.latestSummary,
            currentContent: record.currentContent,
            baseSnapshot: record.baseSnapshot,
            contentBaseGeneratedAt: record.contentBaseGeneratedAt,
            pendingOverwrite: nil
        )
    }

    private func persist(state: ConversationScratchState, for conversationId: UUID) {
        do {
            if shouldPersist(state) {
                try nodeStore.saveScratchPadState(
                    ScratchPadStateRecord(
                        nodeId: conversationId,
                        latestSummary: state.latestSummary,
                        currentContent: state.currentContent,
                        baseSnapshot: state.baseSnapshot,
                        contentBaseGeneratedAt: state.contentBaseGeneratedAt
                    )
                )
            } else {
                try nodeStore.deleteScratchPadState(nodeId: conversationId)
            }
        } catch {
            NSLog("ScratchPadStore persist failed: %@", error.localizedDescription)
        }
    }

    private func shouldPersist(_ state: ConversationScratchState) -> Bool {
        state.latestSummary != nil ||
        !state.currentContent.isEmpty ||
        !state.baseSnapshot.isEmpty ||
        state.contentBaseGeneratedAt != nil
    }

    private func migrateLegacyDefaultsIfNeeded() {
        clearLegacyAppLevelKeys()

        let legacyKeys = defaults.dictionaryRepresentation().keys.filter {
            $0.hasPrefix(Keys.conversationPrefix)
        }
        guard !legacyKeys.isEmpty else { return }

        let conversationIds = Set(legacyKeys.compactMap(conversationId(from:)))
        for conversationId in conversationIds {
            let legacyState = loadLegacyState(conversationId: conversationId)
            defer { removeLegacyConversationKeys(for: conversationId) }

            guard shouldPersist(legacyState) else { continue }
            guard (try? nodeStore.fetchNode(id: conversationId)) != nil else { continue }
            guard (try? nodeStore.fetchScratchPadState(nodeId: conversationId)) == nil else { continue }
            persist(state: legacyState, for: conversationId)
        }
    }

    private func clearLegacyAppLevelKeys() {
        defaults.removeObject(forKey: Keys.legacyLatest)
        defaults.removeObject(forKey: Keys.legacyContent)
        defaults.removeObject(forKey: Keys.legacyBase)
        defaults.removeObject(forKey: Keys.legacyBaseDate)
    }

    private func loadLegacyState(conversationId: UUID) -> ConversationScratchState {
        let latestSummary: ScratchSummary?
        if let data = defaults.data(forKey: Keys.latestSummary(conversationId)),
           let decoded = try? JSONDecoder().decode(ScratchSummary.self, from: data) {
            latestSummary = decoded
        } else {
            latestSummary = nil
        }

        let currentContent = defaults.string(forKey: Keys.content(conversationId)) ?? ""
        let baseSnapshot = defaults.string(forKey: Keys.base(conversationId)) ?? ""
        let contentBaseGeneratedAt: Date?
        if let raw = defaults.object(forKey: Keys.baseDate(conversationId)) as? Double {
            contentBaseGeneratedAt = Date(timeIntervalSince1970: raw)
        } else {
            contentBaseGeneratedAt = nil
        }

        return ConversationScratchState(
            latestSummary: latestSummary,
            currentContent: currentContent,
            baseSnapshot: baseSnapshot,
            contentBaseGeneratedAt: contentBaseGeneratedAt,
            pendingOverwrite: nil
        )
    }

    private func removeLegacyConversationKeys(for conversationId: UUID) {
        defaults.removeObject(forKey: Keys.latestSummary(conversationId))
        defaults.removeObject(forKey: Keys.content(conversationId))
        defaults.removeObject(forKey: Keys.base(conversationId))
        defaults.removeObject(forKey: Keys.baseDate(conversationId))
    }

    private func conversationId(from key: String) -> UUID? {
        guard key.hasPrefix(Keys.conversationPrefix) else { return nil }
        let suffixes = [
            ".latestSummary",
            ".content",
            ".base",
            ".baseDate"
        ]
        guard let suffix = suffixes.first(where: { key.hasSuffix($0) }) else { return nil }
        let start = key.index(key.startIndex, offsetBy: Keys.conversationPrefix.count)
        let end = key.index(key.endIndex, offsetBy: -suffix.count)
        guard start <= end else { return nil }
        return UUID(uuidString: String(key[start..<end]))
    }
}
