import Foundation

/// UserDefaults-backed snapshot of Galaxy node positions, keyed by store
/// identity so layout state never leaks across SQLite databases /
/// workspaces / DB resets. Used as `seedPositions` for
/// `GraphEngine.computeLayout` so reopening Galaxy converges back to
/// the user's last settled layout.
///
/// Not transactional with the SQLite store — a node deleted between
/// sessions leaves a stale entry until the next write prunes naturally
/// (computeLayout ignores entries without a matching node).
final class PositionSnapshotStore {
    private let storeId: String
    private let defaults: UserDefaults

    init(storeId: String, defaults: UserDefaults = .standard) {
        self.storeId = storeId
        self.defaults = defaults
    }

    static func key(forStoreId storeId: String) -> String {
        "com.nous.galaxy.positionSnapshot.v1.\(storeId)"
    }

    /// Writes the snapshot. Best-effort — failures are silent and
    /// non-fatal (Galaxy still works without a remembered layout).
    func write(positions: [UUID: GraphPosition]) {
        let dict: [String: [Float]] = positions.reduce(into: [:]) { result, kv in
            result[kv.key.uuidString] = [kv.value.x, kv.value.y]
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: dict, options: [])
            defaults.set(data, forKey: Self.key(forStoreId: storeId))
        } catch {
            // best-effort; non-fatal
        }
    }

    /// Reads the snapshot. Absent or corrupt data returns an empty
    /// dictionary (never throws, never crashes).
    func read() -> [UUID: GraphPosition] {
        guard let data = defaults.data(forKey: Self.key(forStoreId: storeId)) else { return [:] }
        // JSONSerialization decodes JSON numbers as NSNumber — when bridged to
        // Swift array element types it surfaces as [Double] for [Float] arrays.
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [String: [Double]] else {
            return [:]
        }
        var out: [UUID: GraphPosition] = [:]
        for (k, v) in raw {
            guard let uuid = UUID(uuidString: k), v.count >= 2 else { continue }
            out[uuid] = GraphPosition(x: Float(v[0]), y: Float(v[1]))
        }
        return out
    }
}
