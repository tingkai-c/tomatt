# Usable LAN Sync G001 Audit

This audit records the concrete touchpoints for the complete usable multi-device LAN sync pass.

## Current State

- `proto/tomatt/sync/v1/tomatt_sync.proto` has v1 envelope, control, encrypted LAN payload, transcript-carrying pairing messages, resume Hello metadata, and anti-entropy messages. Future schema changes must be additive.
- `tomatt/SyncProtocol/Generated/tomatt/sync/v1/tomatt_sync.pb.swift` is committed generated SwiftProtobuf output and must remain consistent with the proto.
- `tomatt/SyncProtocol/AntiEntropySyncEngine.swift` supports encrypted multi-origin anti-entropy, retained signed-event re-export, acknowledgements, backlog continuation, and local-event notifications.
- `tomatt/SyncSecurity/SyncSecurity.swift` has Keychain/file-backed sync storage, signed-event sidecar retention, trusted import with original-signer validation, membership interval validation, storage health, reset semantics, and fail-closed sidecar persistence.
- `tomatt/SyncSecurity/SyncSessionSecurity.swift` has AES-GCM message sealing/opening over pairing-derived or resume-derived session material, plus exact HKDF reconnect hydration from the sync-group key.
- `tomatt/LANTransport/LANTransport.swift` defines mDNS/DNS-SD TXT metadata without stable IDs, WebSocket frame codec, URLSession client, SwiftNIO/NIOWebSocket listener, heartbeat/backoff, runtime start/stop, and duplicate connection primitives while remaining trust/import blind.
- `tomatt/SyncRuntime/SyncService.swift` and `tomatt/SyncProtocol/TBLANEncryptedSessionRouter.swift` own app-level runtime orchestration, pairing setup vs LAN sync gates, encrypted session routing, pairing transcript exchange, resume admission, Settings actions, reset/remove behavior, and projection refresh triggers.
- `tomatt/PairingCore/PairingCore.swift` keeps internal Add/Join roles, transcript code, idle gates, preview, settings-source choice, pairing key agreement, and staged commit model while the user-facing UI exposes one Pair Device flow.
- `tomatt/SyncUI/SyncSettingsModel.swift` and `tomatt/SyncUI/SyncSettingsView.swift` are service-backed and expose Pair Device / Pair by Address / Reset / Remove controls without top-level Add/Join labels. Cloud Relay remains disabled/future.
- `tomatt/EventCore.swift` owns the raw local event log, syncable envelope fields, membership events/projection, anti-entropy primitives, and deterministic timer conflict projection.

## Implementation Touchpoints

- Protocol: `proto/tomatt/sync/v1/tomatt_sync.proto`, generated SwiftProtobuf files, `tomatt/SyncProtocol/TomattSyncProtoMapper.swift`, `tomattTests/SyncProtocolCompatibilityTests.swift`, `tomattTests/SyncProtoMapperTests.swift`.
- Security/storage: `tomatt/SyncSecurity/SyncSecurity.swift`, `tomatt/SyncSecurity/SyncSessionSecurity.swift`, new signed-event store file(s), app-support storage helpers, `tomattTests/SyncSecurityTests.swift`, `tomattTests/SyncSessionSecurityTests.swift`, new `SignedSyncEventStoreTests`.
- Event/membership: `tomatt/EventCore.swift`, `tomattTests/EventCoreTests.swift`.
- Anti-entropy: `tomatt/SyncProtocol/AntiEntropySyncEngine.swift`, `tomattTests/AntiEntropySyncEngineTests.swift`, new multi-device fake integration tests.
- Pairing: `tomatt/PairingCore/PairingCore.swift`, `tomattTests/PairingCoreTests.swift`, possible new pairing-flow tests.
- Transport: `tomatt/LANTransport/LANTransport.swift`, `tomattTests/LANTransportTests.swift`.
- Runtime/UI: `tomatt/App.swift`, `tomatt/Timer.swift`, `tomatt/View.swift`, `tomatt/SyncUI/SyncSettingsModel.swift`, `tomatt/SyncUI/SyncSettingsView.swift`, `tomattTests/SyncSettingsModelTests.swift`, new runtime coordinator tests.
- Docs/status: `docs/sync-design-decisions.md`, `docs/sync-implementation-status.md`, `docs/adr/0007-signed-event-retention-and-multi-origin-relay.md`, `docs/adr/0008-manual-address-pairing-and-lan-runtime-port.md`, `docs/adr/0009-sync-runtime-status-and-reset.md`.

## Boundary Gates

- `SyncCore` must not import SwiftProtobuf, Network, SwiftUI, AppKit, LANTransport, or SyncUI.
- LANTransport must not call raw event import APIs or decide trust.
- Manual address code must use the same pairing/session/import path as Bonjour-discovered peers.
- Cloud Relay must remain disabled/future.
