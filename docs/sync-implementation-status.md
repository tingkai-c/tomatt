# Sync Implementation Status

This document summarizes the first implementation pass for tomatt's local-first sync architecture and outlines the recommended next pass.

## Implementation Pass 1: Local Event-Log Foundation

Status: **completed and delivered**

Commit range:

- `94ada19 Add local event log persistence`
- `e1e0d4e Record event log delivery`

CI delivery run:

- Build/sign/notarize: <https://github.com/tingkai-c/tomatt/actions/runs/27393842066>
- Tests: <https://github.com/tingkai-c/tomatt/actions/runs/27393842068>

### What changed

The first implementation pass intentionally stayed **local-only**. It did not implement LAN sync, Cloudflare, APNs, crypto, or a Settings → Sync pane.

Implemented pieces:

- Added `tomatt/EventCore.swift`.
- Added an append-only local JSONL event store at:
  - `~/Library/Application Support/tomatt/events.jsonl`
- Added event envelopes and event projections for local app state.
- Moved shared stats/preset snapshot domain types into `TimerCore.swift` so event core and stats can share them.
- Added `tomattTests/EventCoreTests.swift`.
- Updated stats tests for event-log-backed stats.

### Event-sourced domains in this pass

The following now use the local event log:

- Shared timer settings:
  - `pauseAfterRestFinish`
  - `extendWorkAfterFinish`
- Named presets:
  - add
  - duplicate
  - rename
  - update
  - delete
  - reorder
  - select active preset
- Active timer restore snapshot:
  - old `activeTimerSession` AppStorage is ignored
  - new restore state is projected from `events.jsonl`
- New stats records:
  - old `session-records.jsonl` is ignored
  - new stats are stored as event-log records
- Timer lifecycle facts are emitted locally:
  - timer started
  - timer paused
  - timer resumed
  - timer stopped
  - timer skipped
  - timer completed

### Explicitly not done

Deferred by design:

- LAN discovery and pairing.
- Anti-entropy peer sync.
- Cloudflare KV mailbox.
- APNs wakeups.
- Crypto/signing/envelope encryption.
- Settings → Sync UI.
- iOS/iPadOS app work.
- Screen Time enforcement.
- Migration of old local stats/settings.

### Important behavior decisions preserved

- Legacy data is ignored, not actively deleted.
- Restore is runtime reconstruction, not a durable `timerRestored` event.
- Device-local settings remain local/AppStorage-backed:
  - menu bar visibility
  - full-screen mask settings
  - strict mask settings
  - appearance
  - launch at login
  - keyboard shortcuts
  - sound volumes
- Current timer edge behaviors are preserved, including:
  - pause after rest finish
  - extend work after finish
  - work-finished pending break
  - long-rest reset behavior

### Review and verification

- Local static check: `git diff --check` passed.
- `swiftlint` was unavailable locally.
- No local `xcodebuild` or local signing was run.
- Independent architect review returned `CLEAR`.
- Independent code review returned `APPROVE` after fixes.
- GitHub Actions tests passed.
- GitHub Actions signed/notarized artifact was downloaded, verified, installed, and launched.

## Known caveats after Pass 1

- The event log is local-only; it does not yet sync to another device.
- The active timer restore path uses event-log-backed active-session snapshots for compatibility with current timer behavior. Timer lifecycle events are also emitted, but the full future distributed projection model is not yet complete.
- Old local data may still exist on disk/AppStorage, but normal code paths no longer use it for the event-sourced domains.
- There is not yet a user-visible sync status surface.

## Implementation Pass 2: SyncCore Primitives

Status: **completed and delivered**

Commit:

- `f2b6a00 Add sync core primitives`

CI delivery run:

- Build/sign/notarize: <https://github.com/tingkai-c/tomatt/actions/runs/27398520677>

This pass intentionally stayed inside SyncCore primitives. It did **not** add live Bonjour/Network.framework sockets, Cloudflare, APNs, crypto/signing, local-network `Info.plist` keys, network entitlements, workflow edits, or Sync UI.

### What changed

- Added a stable local device identity model and injectable store (`TBDeviceIdentity`, `TBDeviceIdentityStoring`, `TBFileDeviceIdentityStore`). This is a local identifier/display-name only; it is not a trust, account, signing, or key model.
- Evolved `TBEventEnvelope` additively to schema v2 while preserving v1 decode compatibility:
  - existing fields remain `eventID: UUID`, `streamID: String`, and `sequence: Int64`
  - new replicated fields are `originDeviceID: String?` and `deviceSequence: Int64?`
  - v1 log lines continue to decode/project locally but are not exported as sync events and are not rewritten.
- Added deterministic event-ID derivation for syncable v2 events from a stable namespace plus `originDeviceID:deviceSequence`.
- Added syncability classification for all current event cases:
  - syncable: settings, presets, timer lifecycle, stats, and membership
  - local-only: `activeTimerSessionPersisted` and `activeTimerSessionCleared`
- Added membership events and projection for `devicePaired`, `deviceRenamed`, and `deviceRemoved`. Membership is only projected log state; there is no real pairing or trust establishment yet.
- Added anti-entropy primitives:
  - `syncSummary() -> [String: Int64]`
  - `missingEvents(relativeTo:)`
  - strict `importEvents(_:) -> TBImportResult`

### v2 sequencing and local-only behavior

`deviceSequence` is allocated only to syncable events. Local-only active timer restore snapshots keep nil replicated fields and use legacy/local ordering only. They do not consume device sequence numbers and therefore do not create anti-entropy gaps.

The next local device sequence is computed as:

```text
max(deviceSequence where originDeviceID == localDeviceID and event is syncable v2) + 1
```

Projection order is deterministic and independent of append order:

```text
recordedAt, originDeviceID ?? streamID, deviceSequence ?? sequence, eventID.uuidString
```

### Watermark invariant

`syncSummary()` reports the highest **contiguous** syncable v2 `deviceSequence` watermark per origin device. Valid out-of-order imports are buffered in the log, but a watermark does not advance across a gap. Export/import is limited to syncable v2 events; remote local-only events, missing replicated fields, future schema versions, duplicate/colliding event IDs, and origin/sequence collisions are handled without crashing.

### Still deferred

- Cloudflare KV mailbox.
- APNs.
- Bonjour/Network.framework LAN transport.
- Local-network permission strings and network entitlements.
- Real pairing, trust, signing, or revocation.
- Sync UI, including Add Device / Join Sync Group.
- iOS/iPadOS app.
- Screen Time blocking.
- Multi-user/team sync.
- Multiple sync groups.
- Cryptographic revocation/key rotation.

## Implementation Pass 3: Cross-Platform LAN Sync Skeleton and Gated Sync Surface

Status: **completed and delivered**

Commit:

- `fffe715 Add LAN sync foundation`

CI delivery run:

- Build/sign/notarize: <https://github.com/tingkai-c/tomatt/actions/runs/27405487995>

Installed artifact:

- `/tmp/tomatt-ci-artifact-27405487995/download/tomatt-fffe715/tomatt-fffe715.zip`
- Installed to `/Applications/tomatt.app`
- Previous app backup: `/Applications/tomatt.app.backup-20260612T165746`

This pass implements the cross-platform LAN sync protocol, security model, pairing model, encrypted in-memory anti-entropy engine, deterministic distributed timer conflict projection, and a gated Settings → Sync surface. It still does **not** ship a real live LAN WebSocket server/client connection path; the Settings UI explicitly disables LAN setup actions until that transport is productized.

### What changed

- Added the canonical Protobuf schema at `proto/tomatt/sync/v1/tomatt_sync.proto` with package `tomatt.sync.v1`.
- Added generated SwiftProtobuf wire bindings under `tomatt/SyncProtocol/Generated/` and pinned SwiftProtobuf `1.38.0`.
- Added a protobuf-free `SyncCore` façade over existing event-log anti-entropy primitives.
- Added SyncProtocol mapping helpers and protocol convention tests.
- Added SyncSecurity models for:
  - display identity vs cryptographic sync identity separation
  - trusted peer records
  - sync-group key lifecycle abstractions
  - CryptoKit Ed25519 signing/verification
  - interim canonical signed event bytes
  - signed-event trusted import before raw event-log import
- Added ADR 0006 for sync event signing and trusted import.
- Added an internal-only LAN transport skeleton for:
  - `_tomatt-sync._tcp`
  - `/tomatt-sync`
  - `tomatt.sync.v1.protobuf`
  - minimal mDNS TXT metadata without stable `deviceId`
  - binary Protobuf envelope frame encode/decode
  - `Hello`, `Ping`, `Pong`
  - heartbeat/backoff and duplicate-connection placeholders
- Added PairingCore for verified LAN pairing:
  - Add Device / Join Sync Group roles
  - idle gates
  - deterministic transcript-derived six-digit code
  - pre-merge preview
  - settings-source choice
  - staged all-or-nothing commit
- Added authenticated encrypted session/message support using CryptoKit AES-GCM over serialized Protobuf envelopes.
- Added an encrypted anti-entropy engine under `SyncProtocol` for in-memory paired peers:
  - event summaries
  - missing-event requests
  - signed event batches
  - event-batch acknowledgements
  - new-events-available notifications
- Added deterministic distributed timer conflict projection:
  - branch identity is `sessionId`
  - overlapping branches resolve by earliest start
  - tie-breakers use session ID, origin, sequence, and event ID
  - losing branches remain in the log but are excluded from normal timer/stats projection
  - correction notice model is pure and UI-independent
- Added a gated Settings → Sync pane:
  - Off / LAN only / LAN + Cloud Relay modes
  - Cloud Relay marked future/unavailable
  - LAN setup disabled until real LAN server/client transport is productized
  - device/status/paired-device/unpair copy
  - local-network permission and encryption copy
- Added macOS local-network usage description, Bonjour service declaration, and sandbox network client/server entitlements for future LAN transport.

### Important current limitations

- Real LAN WebSocket listener/client networking is still not productized.
- Settings → Sync is a gated setup/status surface; it does not claim active LAN sync in this build.
- The anti-entropy engine is currently an in-memory encrypted peer harness, not connected to live mDNS/WebSocket networking.
- Multi-hop relay of third-party-origin signed events is deferred until original signed-event metadata is retained for re-export; the current engine only advertises and exports events originated by its local signer device.
- Keychain storage has production-facing protocols and a bounded Apple adapter boundary, but tests use in-memory stores.
- Canonical event signing uses interim sorted-key JSON over existing event envelopes until the long-term Protobuf event payload model is finalized.
- Cloud Relay, APNs, Android/Linux clients, Screen Time, manual IP pairing, and cryptographic revocation/key rotation remain out of scope.

### Verification before delivery

Local static/non-build checks run during this pass:

- `git diff --check`
- `plutil -lint tomatt.xcodeproj/project.pbxproj`
- `plutil -lint tomatt/tomatt.entitlements`
- `python3 -m json.tool tomatt.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`
- targeted Swift parse/typecheck checks that do not invoke local Xcode builds
- boundary searches for SyncCore/wire separation and raw-import avoidance

No local Xcode build, signing, notarization, packaging, or artifact build was run.

### Transport decisions implemented in schema/skeleton

- LAN discovery uses mDNS/DNS-SD service type `_tomatt-sync._tcp`.
- LAN sessions use WebSocket connections with Protobuf binary frames.
- User builds expose only the sync WebSocket endpoint:
  - path: `/tomatt-sync`
  - subprotocol: `tomatt.sync.v1.protobuf`
- Protobuf schemas live in this repository initially, likely under `proto/tomatt/sync/v1/tomatt_sync.proto`.
- The Protobuf package is `tomatt.sync.v1`.
- Swift implementation now uses SwiftProtobuf for generated messages. A real Apple WebSocket listener/client is still deferred; the current LAN transport is a skeleton/model, not a live server/client.
- Generated Swift Protobuf files should be committed initially to avoid CI/tooling fragility.

### Protocol shape implemented in schema/model

- One WebSocket binary frame carries one top-level Protobuf envelope.
- The envelope includes message ID, optional response/correlation ID, sent timestamp, version metadata where appropriate, and a `oneof` payload.
- Session-layer messages include `Hello`, `Ping`, `Pong`, pairing messages, capability negotiation, and typed errors.
- Sync-layer messages include event summaries, missing-event requests, event batches, event-batch acknowledgements, and new-events-available notifications.
- `Hello` includes protocol major/minor version, app version/build, platform, display name where appropriate, and capabilities.
- Peers require matching protocol major version; minor differences are handled through capability negotiation.
- Protocol timestamps use `google.protobuf.Timestamp`.
- UUID-like IDs are canonical lowercase UUID strings.
- Duration fields use integer seconds.
- Protobuf compatibility discipline applies from the start: never reuse field numbers, reserve removed fields, and use new packages such as `tomatt.sync.v2` for breaking changes.

### Discovery and privacy behavior implemented in skeleton/model

- mDNS TXT records should expose only minimal routing/compatibility metadata:
  - `proto=tomatt-sync`
  - `v=1`
  - `transport=ws`
  - `encoding=protobuf`
  - `disc=<ephemeral discovery id>`
- Stable `deviceId` values are not advertised through mDNS.
- During explicit pairing/setup discovery, the service instance name may include the user-visible display name for easier selection.
- Outside pairing/setup mode, advertisements should use a generic instance name and ephemeral discovery ID.
- No manual IP/host fallback is planned for v1.

### Connection behavior still planned for live LAN transport

- Use hybrid discovery:
  - broad browse/advertise while pairing/setup is active
  - opportunistic reconnect for paired devices while LAN sync is enabled and the app is active/reachable
- Either side may initiate outbound WebSocket connection after discovery.
- Resolve duplicate connections deterministically by stable `deviceId` after identity is revealed/verified.
- Keep persistent-ish connections open while reachable.
- Use application-level `Ping`/`Pong` heartbeat, with native WebSocket ping/pong optional when convenient.
- Use reconnect/backoff starting around one second and backing off to about one minute with jitter.

### Pairing constraints implemented in core model

- Discovery and `Hello` may occur before pairing, but sync event exchange is only allowed after pairing/trust.
- Stable device IDs are exchanged inside the pairing handshake, not advertised in mDNS.
- Pairing uses long-lived device keypairs and a six-digit verification code derived from the handshake transcript/public keys.
- Pairing sessions expire after roughly two to five minutes.
- Both devices must confirm the code.
- Both devices must approve the pre-merge preview before membership or sync events are written.
- Pre-merge preview should include device names/platforms, both idle status, settings-differ flag, preset counts, history counts, and history date ranges.

### Out of scope for the next pass unless explicitly reopened

- User-facing plaintext sync.
- Real live LAN WebSocket listener/client hookup.
- Cloudflare relay transport.
- APNs.
- Android/Linux client implementations.
- Screen Time blocking.
- Manual IP pairing fallback.
