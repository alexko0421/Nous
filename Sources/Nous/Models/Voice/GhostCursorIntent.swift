import Foundation
import CoreGraphics

enum GhostCursorPhase: String, Codable, Equatable {
    case hidden
    case traveling
    case arrived
    case error
}

enum GhostCursorEasing: String, Codable, Equatable {
    /// cubic-bezier(0.22, 0.84, 0.26, 1.0) — smooth landing, no overshoot.
    case smooth
    /// cubic-bezier(0.16, 1.18, 0.30, 1.0) — slight overshoot for expressive hops.
    case expressive
}

struct GhostCursorIntent: Codable, Equatable, Identifiable {
    let id: UUID
    let targetId: String
    let easing: GhostCursorEasing
    let createdAt: Date

    init(
        id: UUID = UUID(),
        targetId: String,
        easing: GhostCursorEasing = .smooth,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.targetId = targetId
        self.easing = easing
        self.createdAt = createdAt
    }

    /// Travel duration in milliseconds, distance-driven and clamped 320…560 ms.
    /// Formula ported from openai/realtime-voice-component `src/useGhostCursor.ts`.
    /// Constants are intentional: short hops feel snappy (320 ms floor), long hops
    /// feel deliberate (560 ms ceiling).
    static func travelDurationMs(distance: Double) -> Double {
        let raw = 320.0 + distance * 0.18
        return min(560.0, max(320.0, raw))
    }

    static func travelDurationMs(from origin: CGPoint, to target: CGPoint) -> Double {
        let dx = Double(target.x - origin.x)
        let dy = Double(target.y - origin.y)
        return travelDurationMs(distance: (dx * dx + dy * dy).squareRoot())
    }
}
