import Foundation

struct EmbeddingMigrationReport: Equatable {
    var scanned = 0
    var skippedAlreadyCurrent = 0
    var skippedEmptyStatement = 0
    var reembedded = 0
    var failed = 0
}

/// Re-embeds atom rows whose `embedding_signature` no longer matches
/// `EmbeddingService.currentSignature`. Idempotent (skips current-signature
/// rows), batched (per-call cap), resumable (each row commits independently
/// so an app restart resumes from the next row).
final class EmbeddingMigrationRunner {
    private let nodeStore: NodeStore
    private let embed: (String) -> [Float]?
    private let activeSignature: String

    init(
        nodeStore: NodeStore,
        embed: @escaping (String) -> [Float]?,
        activeSignature: String = EmbeddingService.currentSignature
    ) {
        self.nodeStore = nodeStore
        self.embed = embed
        self.activeSignature = activeSignature
    }

    @discardableResult
    func runIfNeeded(maxAtoms: Int = 128) throws -> EmbeddingMigrationReport {
        var report = EmbeddingMigrationReport()
        guard maxAtoms > 0 else { return report }

        let atoms = try nodeStore.fetchMemoryAtoms()
        var processed = 0
        for var atom in atoms {
            if processed >= maxAtoms { break }
            report.scanned += 1

            if atom.embeddingSignature == activeSignature {
                report.skippedAlreadyCurrent += 1
                continue
            }
            let statement = atom.statement.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !statement.isEmpty else {
                report.skippedEmptyStatement += 1
                continue
            }
            guard let vector = embed(statement) else {
                report.failed += 1
                continue
            }
            atom.embedding = vector
            atom.embeddingSignature = activeSignature
            atom.updatedAt = Date()
            try nodeStore.updateMemoryAtom(atom)
            report.reembedded += 1
            processed += 1
        }
        return report
    }
}
