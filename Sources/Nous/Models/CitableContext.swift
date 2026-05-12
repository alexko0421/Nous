import Foundation

/// Result of `CitableContextBuilder.build(...)`. Bundles the selected
/// `[CitableEntry]` with a manifest that records what was considered, what was
/// admitted, and why entries dropped. The manifest is read by Block 7
/// observability — do not strip fields without updating the telemetry contract.
struct CitableContext: Equatable {
    let entries: [CitableEntry]
    let manifest: CitableContextManifest

    static let empty = CitableContext(entries: [], manifest: .empty)
}

struct CitableContextManifest: Equatable {
    let mode: ChatMode
    let intent: MemoryQueryIntent?
    let totalCandidates: Int
    let droppedByConfidenceFloor: Int
    let droppedByBudget: Int
    /// Entries suppressed because their aggregated thumbs-down penalty from
    /// `CitationFeedbackStore` crossed the suppression threshold. Separate
    /// from `droppedByBudget` so a sudden spike is visible in telemetry.
    let droppedByFeedback: Int
    let admittedCount: Int
    let timeWindowStart: Date?
    let timeWindowEnd: Date?

    static let empty = CitableContextManifest(
        mode: .companion,
        intent: nil,
        totalCandidates: 0,
        droppedByConfidenceFloor: 0,
        droppedByBudget: 0,
        droppedByFeedback: 0,
        admittedCount: 0,
        timeWindowStart: nil,
        timeWindowEnd: nil
    )
}
