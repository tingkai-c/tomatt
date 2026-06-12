import XCTest

final class SyncCoreTests: XCTestCase {
    func testFacadeExportsSummaryAndMissingBatch() throws {
        let localDeviceID = "00000000-0000-0000-0000-000000000101"
        let remoteSummary: TBSyncWatermarkSummary = [localDeviceID: 1]
        let log = try makeLog(deviceID: localDeviceID)
        log.append(.settingChanged(TBSettingChanged(key: .workDurationMinutes, value: .int(25))))
        log.append(.settingChanged(TBSettingChanged(key: .shortRestDurationMinutes, value: .int(5))))

        let facade = TBSyncEventLogFacade(eventLog: log)
        let batch = facade.missingEvents(for: TBSyncMissingEventsRequest(remoteSummary: remoteSummary))

        XCTAssertEqual(facade.localSummary(), [localDeviceID: 2])
        XCTAssertEqual(batch.events.map(\.deviceSequence), [2])
    }

    func testFacadeImportsOnlyThroughTrustedImportBoundary() throws {
        let originDeviceID = "00000000-0000-0000-0000-000000000102"
        let receiverDeviceID = "00000000-0000-0000-0000-000000000103"
        let sender = try makeLog(deviceID: originDeviceID)
        let receiver = try makeLog(deviceID: receiverDeviceID)
        sender.append(.settingChanged(TBSettingChanged(key: .workDurationMinutes, value: .int(45))))
        let batch = TBSyncEventBatch(events: sender.missingEvents(relativeTo: [:]))

        let outcome = TBSyncEventLogFacade(eventLog: receiver).importAlreadyVerifiedEvents(batch)

        XCTAssertEqual(outcome.imported, 1)
        XCTAssertEqual(receiver.syncSummary(), [originDeviceID: 1])
    }

    private func makeLog(deviceID: String) throws -> TBLocalEventLog {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let identity = TBDeviceIdentity(deviceID: deviceID, displayName: "Test Mac", platform: "macOS")
        return TBLocalEventLog(store: TBJSONLEventStore(fileURL: directory.appendingPathComponent("events.jsonl")),
                               identity: identity)
    }
}
