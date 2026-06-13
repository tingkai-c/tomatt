import Foundation

enum TomattSyncProtocolV1 {
    static let supportedMajorVersion: UInt32 = 1
    static let supportedMinorVersion: UInt32 = 0

    static func isCompatibleHello(_ hello: Tomatt_Sync_V1_Hello) -> Bool {
        hello.protocolMajor == supportedMajorVersion && hello.protocolMinor <= supportedMinorVersion
    }

    static func isCompatibleEnvelope(_ envelope: Tomatt_Sync_V1_Envelope) -> Bool {
        envelope.protocolMajor == supportedMajorVersion && envelope.protocolMinor <= supportedMinorVersion
    }

    static func isCanonicalLowercaseUUIDString(_ value: String) -> Bool {
        guard UUID(uuidString: value)?.uuidString.lowercased() == value else {
            return false
        }

        return value == value.lowercased()
    }
}
