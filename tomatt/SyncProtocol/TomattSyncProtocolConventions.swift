import Foundation

enum TomattSyncProtocolV1 {
    static let supportedMajorVersion: UInt32 = 1

    static func isCompatibleHello(_ hello: Tomatt_Sync_V1_Hello) -> Bool {
        hello.protocolMajor == supportedMajorVersion
    }

    static func isCanonicalLowercaseUUIDString(_ value: String) -> Bool {
        guard UUID(uuidString: value)?.uuidString.lowercased() == value else {
            return false
        }

        return value == value.lowercased()
    }
}
