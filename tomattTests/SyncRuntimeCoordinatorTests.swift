import Foundation
import XCTest

final class SyncRuntimeCoordinatorTests: XCTestCase {
    func testLANStartsOnlyWhenStorageHealthReady() {
        let lan = FakeLANRuntime()
        let coordinator = TBSyncRuntimeCoordinator(
            healthChecker: FakeHealthChecker(health: TBSyncStorageHealth(status: .ready)),
            lanRuntime: lan
        )

        let started = coordinator.setMode(.lanOnly, discoveryID: LANDiscoveryID(rawValue: "disc"))

        XCTAssertTrue(started)
        XCTAssertEqual(coordinator.mode, .lanOnly)
        XCTAssertTrue(lan.didStart)
        XCTAssertEqual(lan.status, .active(port: 40484))
        XCTAssertTrue(coordinator.statusEvents.contains(.lanStarted(port: 40484)))
    }

    func testStorageHealthBlocksLANAndRequiresResetState() {
        let lan = FakeLANRuntime()
        let coordinator = TBSyncRuntimeCoordinator(
            healthChecker: FakeHealthChecker(health: TBSyncStorageHealth(status: .lanSyncDisabledRequiresReset("corrupt device signing key"))),
            lanRuntime: lan
        )
        coordinator.markDiscovered(deviceID: "peer-a", displayName: "Peer A")

        let started = coordinator.setMode(.lanOnly, discoveryID: LANDiscoveryID(rawValue: "disc"))

        XCTAssertFalse(started)
        XCTAssertTrue(lan.didStop)
        XCTAssertEqual(coordinator.peers["peer-a"]?.state, .resetRequired("corrupt device signing key"))
        XCTAssertTrue(coordinator.statusEvents.contains(.storageBlocked(.lanSyncDisabledRequiresReset("corrupt device signing key"))))
    }

    func testOffStopsLANAndReconnectAttempts() {
        let lan = FakeLANRuntime()
        let coordinator = TBSyncRuntimeCoordinator(
            healthChecker: FakeHealthChecker(health: TBSyncStorageHealth(status: .ready)),
            lanRuntime: lan
        )
        _ = coordinator.setMode(.lanOnly)

        _ = coordinator.setMode(.off)

        XCTAssertTrue(lan.didStop)
        XCTAssertFalse(lan.shouldReconnect)
        XCTAssertEqual(coordinator.mode, .off)
        XCTAssertTrue(coordinator.statusEvents.contains(.lanStopped))
    }

    func testPeerStateMachineAndConnectionSyncTrigger() {
        let engine = FakePeerEngine(beginResult: TBAntiEntropySyncStepResult(statuses: [.summaryReceived(deviceID: "peer-a", eventCount: 2)]))
        let coordinator = TBSyncRuntimeCoordinator(
            healthChecker: FakeHealthChecker(health: TBSyncStorageHealth(status: .ready)),
            lanRuntime: FakeLANRuntime(),
            now: { Date(timeIntervalSince1970: 100) }
        )

        coordinator.registerEngine(engine, for: "peer-a", displayName: "Peer A")
        coordinator.markDiscovered(deviceID: "peer-a", displayName: "Peer A")
        XCTAssertTrue(coordinator.beginConnection(to: "peer-a"))
        coordinator.beginPairing(deviceID: "peer-a")
        coordinator.beginVerification(deviceID: "peer-a")
        _ = coordinator.triggerConnectionEstablishedSync(deviceID: "peer-a")

        XCTAssertEqual(engine.beginSyncCount, 1)
        XCTAssertEqual(coordinator.peers["peer-a"]?.state, .upToDate)
        XCTAssertTrue(coordinator.statusEvents.contains(.syncTriggered(deviceID: "peer-a", reason: .connectionEstablished)))
        XCTAssertTrue(coordinator.statusEvents.contains(.syncStatus(deviceID: "peer-a", .summaryReceived(deviceID: "peer-a", eventCount: 2))))
    }

    func testSyncErrorDoesNotMarkPeerUpToDate() {
        let engine = FakePeerEngine(beginResult: TBAntiEntropySyncStepResult(statuses: [.error(.protocolViolation("bad payload"))]))
        let now = Date(timeIntervalSince1970: 100)
        let coordinator = TBSyncRuntimeCoordinator(
            healthChecker: FakeHealthChecker(health: TBSyncStorageHealth(status: .ready)),
            lanRuntime: FakeLANRuntime(),
            now: { now }
        )

        coordinator.registerEngine(engine, for: "peer-a", displayName: "Peer A")
        _ = coordinator.triggerConnectionEstablishedSync(deviceID: "peer-a")

        XCTAssertEqual(coordinator.peers["peer-a"]?.state, .retryScheduled(now))
    }

    func testLocalEventAppendNotifiesAllRegisteredNonRemovedPeers() {
        let peerA = FakePeerEngine()
        let peerB = FakePeerEngine()
        let coordinator = TBSyncRuntimeCoordinator(
            healthChecker: FakeHealthChecker(health: TBSyncStorageHealth(status: .ready)),
            lanRuntime: FakeLANRuntime()
        )

        coordinator.registerEngine(peerA, for: "peer-a")
        coordinator.registerEngine(peerB, for: "peer-b")
        coordinator.markRemoved(deviceID: "peer-b")
        _ = coordinator.triggerLocalSyncableEventAppended()

        XCTAssertEqual(peerA.notifyCount, 1)
        XCTAssertEqual(peerB.notifyCount, 0)
        XCTAssertEqual(coordinator.peers["peer-b"]?.state, .removed)
    }

    func testRemovedPeerCannotConnectOrSync() {
        let engine = FakePeerEngine()
        let coordinator = TBSyncRuntimeCoordinator(
            healthChecker: FakeHealthChecker(health: TBSyncStorageHealth(status: .ready)),
            lanRuntime: FakeLANRuntime()
        )
        coordinator.registerEngine(engine, for: "peer-a")
        coordinator.markRemoved(deviceID: "peer-a")

        XCTAssertFalse(coordinator.beginConnection(to: "peer-a"))
        _ = coordinator.triggerConnectionEstablishedSync(deviceID: "peer-a")

        XCTAssertEqual(engine.beginSyncCount, 0)
        XCTAssertEqual(coordinator.peers["peer-a"]?.state, .removed)
    }

    func testCloudRelayModeDoesNotStartCloudPathButRecordsUnavailableAndCanStartLAN() {
        let lan = FakeLANRuntime()
        let coordinator = TBSyncRuntimeCoordinator(
            healthChecker: FakeHealthChecker(health: TBSyncStorageHealth(status: .ready)),
            lanRuntime: lan
        )

        let started = coordinator.setMode(.lanAndCloudRelay)

        XCTAssertTrue(started)
        XCTAssertTrue(lan.didStart)
        XCTAssertTrue(coordinator.statusEvents.contains(.cloudRelayUnavailable))
        XCTAssertFalse(coordinator.statusEvents.contains(.modeChanged(.off)))
    }
}

private struct FakeHealthChecker: TBSyncStorageHealthChecking {
    let currentHealth: TBSyncStorageHealth

    init(health: TBSyncStorageHealth) {
        self.currentHealth = health
    }

    func health() -> TBSyncStorageHealth { currentHealth }
}

private final class FakeLANRuntime: TBSyncLANRuntimeControlling {
    private(set) var status: LANTransportStatus = .stopped
    private(set) var shouldReconnect = false
    var onPeerDiscovered: ((LANDiscoveredPeer) -> Void)?
    private(set) var didStart = false
    private(set) var didStop = false
    private(set) var disconnectedPeerIDs: [String] = []

    func start(discoveryID: LANDiscoveryID) {
        didStart = true
        shouldReconnect = true
        status = .active(port: LANTransportInternalPlaintext.defaultPort)
    }

    func stop() {
        didStop = true
        shouldReconnect = false
        status = .stopped
    }

    func markDisconnected(peerID: String, direction: LANDuplicateConnectionDirection, now: Date, jitterUnit: Double) {
        disconnectedPeerIDs.append(peerID)
        shouldReconnect = true
    }
}

private final class FakePeerEngine: TBSyncPeerEngine {
    private let beginResult: TBAntiEntropySyncStepResult
    private(set) var beginSyncCount = 0
    private(set) var notifyCount = 0
    private(set) var receiveCount = 0

    init(beginResult: TBAntiEntropySyncStepResult = TBAntiEntropySyncStepResult()) {
        self.beginResult = beginResult
    }

    func beginSync() -> TBAntiEntropySyncStepResult {
        beginSyncCount += 1
        return beginResult
    }

    func notifyNewLocalEventsAvailable() -> TBAntiEntropySyncStepResult {
        notifyCount += 1
        return TBAntiEntropySyncStepResult()
    }

    func receive(_ message: TBEncryptedLANMessage) -> TBAntiEntropySyncStepResult {
        receiveCount += 1
        return TBAntiEntropySyncStepResult()
    }
}
