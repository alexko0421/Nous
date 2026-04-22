import Foundation
import Observation

/// Owns the ScratchPad panel's state. Two independent fields track:
///   1. `latestSummary` — the most recent <summary> Nous has emitted.
///   2. `currentContent` / `baseSnapshot` / `contentBaseGeneratedAt` — what the
///      panel actually renders, the snapshot it was loaded from, and which
///      summary version produced that snapshot.
///
/// `isDirty` is derived (`currentContent != baseSnapshot`) and drives the "•" in
/// the panel header. `pendingOverwrite` is set only when a newer summary has
/// arrived but the user has unsaved edits; UI must show a confirm alert and then
/// call `acceptPendingOverwrite()` or `rejectPendingOverwrite()`.
@Observable
@MainActor
final class ScratchPadStore {

    // MARK: - Public state (observable)

    private(set) var latestSummary: ScratchSummary?
    private(set) var currentContent: String
    private(set) var baseSnapshot: String
    private(set) var contentBaseGeneratedAt: Date?
    private(set) var pendingOverwrite: ScratchSummary?

    var isDirty: Bool { currentContent != baseSnapshot }

    // MARK: - Dependencies

    private let defaults: UserDefaults

    private enum Keys {
        static let latestSummary = "nous.scratchpad.latestSummary"
        static let currentContent = "nous.scratchpad.content"
        static let baseSnapshot = "nous.scratchpad.baseSnapshot"
        static let baseDate = "nous.scratchpad.contentBaseDate"
    }

    // MARK: - Init

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        if let data = defaults.data(forKey: Keys.latestSummary),
           let decoded = try? JSONDecoder().decode(ScratchSummary.self, from: data) {
            self.latestSummary = decoded
        } else {
            self.latestSummary = nil
        }

        self.currentContent = defaults.string(forKey: Keys.currentContent) ?? ""
        self.baseSnapshot   = defaults.string(forKey: Keys.baseSnapshot) ?? ""

        if let raw = defaults.object(forKey: Keys.baseDate) as? Double {
            self.contentBaseGeneratedAt = Date(timeIntervalSince1970: raw)
        } else {
            self.contentBaseGeneratedAt = nil
        }

        self.pendingOverwrite = nil
    }

    // MARK: - Ingest (ChatViewModel → store)

    /// Called after an assistant reply is finalized. If the text contains a
    /// well-formed <summary> tag, captures it as the latest summary.
    /// No-ops otherwise.
    func ingestAssistantMessage(content: String, sourceMessageId: UUID, now: Date = Date()) {
        guard let markdown = ClarificationCardParser.extractSummary(from: content) else {
            return
        }
        let summary = ScratchSummary(
            markdown: markdown,
            generatedAt: now,
            sourceMessageId: sourceMessageId
        )
        ingest(summary: summary)
    }

    /// Lower-level ingestion used by tests and by `ingestAssistantMessage`.
    func ingest(summary: ScratchSummary) {
        // Skip duplicate-content summaries so the panel doesn't flash a spurious
        // overwrite alert when the LLM emits the same <summary> block twice in a row.
        if latestSummary?.markdown == summary.markdown {
            return
        }
        latestSummary = summary
        persistLatestSummary()
    }

    // MARK: - Panel lifecycle

    /// Called when the panel becomes visible OR when `latestSummary` changes
    /// while the panel is already visible. Implements the load logic from §6
    /// of the spec.
    func onPanelOpened() {
        guard let latest = latestSummary else {
            // Empty state — free-typing mode, no action.
            return
        }

        if let base = contentBaseGeneratedAt, base == latest.generatedAt {
            // Already based on this summary; keep user edits as-is.
            return
        }

        // If the user has typed content before any summary arrived,
        // `isDirty` is false (base was glued), but we must still protect
        // their work by queuing an overwrite rather than silently replacing.
        let hasUserContent = contentBaseGeneratedAt == nil && !currentContent.isEmpty

        if !isDirty && !hasUserContent {
            applyOverwrite(to: latest)
            return
        }

        // Dirty (or user has pre-summary content) + newer summary → queue for user confirmation.
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

    // MARK: - Edits

    func updateContent(_ newValue: String) {
        currentContent = newValue
        defaults.set(newValue, forKey: Keys.currentContent)

        // Free-typing in empty state: keep base glued to content so isDirty stays
        // false until the first summary lands.
        if latestSummary == nil && contentBaseGeneratedAt == nil {
            baseSnapshot = newValue
            defaults.set(newValue, forKey: Keys.baseSnapshot)
        }
    }

    /// Called by the panel after NSSavePanel completes successfully. The on-disk
    /// file becomes the new clean baseline; `contentBaseGeneratedAt` is left
    /// untouched so a newer summary still counts as "newer than what's shown".
    func markDownloaded() {
        baseSnapshot = currentContent
        defaults.set(currentContent, forKey: Keys.baseSnapshot)
    }

    // MARK: - Helpers

    private func applyOverwrite(to summary: ScratchSummary) {
        currentContent = summary.markdown
        baseSnapshot = summary.markdown
        contentBaseGeneratedAt = summary.generatedAt
        defaults.set(summary.markdown, forKey: Keys.currentContent)
        defaults.set(summary.markdown, forKey: Keys.baseSnapshot)
        defaults.set(summary.generatedAt.timeIntervalSince1970, forKey: Keys.baseDate)
    }

    private func persistLatestSummary() {
        guard let latest = latestSummary,
              let data = try? JSONEncoder().encode(latest) else {
            defaults.removeObject(forKey: Keys.latestSummary)
            return
        }
        defaults.set(data, forKey: Keys.latestSummary)
    }
}
