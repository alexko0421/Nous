import XCTest
@testable import Nous

final class PositionSnapshotPersistenceTests: XCTestCase {
    let testStoreId = "test-store-\(UUID().uuidString)"

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: PositionSnapshotStore.key(forStoreId: testStoreId))
        super.tearDown()
    }

    func test_writeThenReadRoundTrip() {
        let snap = PositionSnapshotStore(storeId: testStoreId)
        let id1 = UUID()
        let id2 = UUID()
        let positions: [UUID: GraphPosition] = [
            id1: GraphPosition(x: 1.5, y: -2.5),
            id2: GraphPosition(x: 3.25, y: 0.0)
        ]
        snap.write(positions: positions)
        let loaded = snap.read()
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded[id1]?.x, 1.5)
        XCTAssertEqual(loaded[id1]?.y, -2.5)
        XCTAssertEqual(loaded[id2]?.x, 3.25)
        XCTAssertEqual(loaded[id2]?.y, 0.0)
    }

    func test_absentSnapshotReturnsEmpty() {
        let snap = PositionSnapshotStore(storeId: "definitely-not-present-\(UUID().uuidString)")
        XCTAssertEqual(snap.read().count, 0)
    }

    func test_corruptSnapshotReturnsEmptyNotCrash() {
        let key = PositionSnapshotStore.key(forStoreId: testStoreId)
        UserDefaults.standard.set(Data("not valid json".utf8), forKey: key)
        let snap = PositionSnapshotStore(storeId: testStoreId)
        XCTAssertEqual(snap.read().count, 0)
    }

    func test_storeIdSegregation() {
        let s1Id = "store-1-\(UUID().uuidString)"
        let s2Id = "store-2-\(UUID().uuidString)"
        defer {
            UserDefaults.standard.removeObject(forKey: PositionSnapshotStore.key(forStoreId: s1Id))
            UserDefaults.standard.removeObject(forKey: PositionSnapshotStore.key(forStoreId: s2Id))
        }

        let s1 = PositionSnapshotStore(storeId: s1Id)
        let s2 = PositionSnapshotStore(storeId: s2Id)
        let nodeId = UUID()
        s1.write(positions: [nodeId: GraphPosition(x: 1, y: 2)])
        XCTAssertEqual(s1.read()[nodeId]?.x, 1)
        XCTAssertNil(s2.read()[nodeId])
    }

    func test_emptyPositionsRoundTripsAsEmpty() {
        let snap = PositionSnapshotStore(storeId: testStoreId)
        snap.write(positions: [:])
        XCTAssertEqual(snap.read().count, 0)
    }
}
