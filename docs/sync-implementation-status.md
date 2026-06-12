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

## Recommended Next Pass: LAN Protocol Schema and Transport Skeleton

The next implementation pass should still avoid full user-facing sync until pairing verification and authenticated sessions are ready. It should establish the cross-platform LAN protocol skeleton and message schema that future macOS, iOS/iPadOS, Android, and Linux clients can share.

### Planned transport decisions

- LAN discovery uses mDNS/DNS-SD service type `_tomatt-sync._tcp`.
- LAN sessions use WebSocket connections with Protobuf binary frames.
- User builds expose only the sync WebSocket endpoint:
  - path: `/tomatt-sync`
  - subprotocol: `tomatt.sync.v1.protobuf`
- Protobuf schemas live in this repository initially, likely under `proto/tomatt/sync/v1/tomatt_sync.proto`.
- The Protobuf package is `tomatt.sync.v1`.
- Swift implementation should use SwiftProtobuf for generated messages and SwiftNIO/NIOWebSocket for the Apple WebSocket listener/client unless dependency research finds a better maintained lightweight option.
- Generated Swift Protobuf files should be committed initially to avoid CI/tooling fragility.

### Planned protocol shape

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

### Planned discovery and privacy behavior

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

### Planned connection behavior

- Use hybrid discovery:
  - broad browse/advertise while pairing/setup is active
  - opportunistic reconnect for paired devices while LAN sync is enabled and the app is active/reachable
- Either side may initiate outbound WebSocket connection after discovery.
- Resolve duplicate connections deterministically by stable `deviceId` after identity is revealed/verified.
- Keep persistent-ish connections open while reachable.
- Use application-level `Ping`/`Pong` heartbeat, with native WebSocket ping/pong optional when convenient.
- Use reconnect/backoff starting around one second and backing off to about one minute with jitter.

### Planned pairing constraints

- Discovery and `Hello` may occur before pairing, but sync event exchange is only allowed after pairing/trust.
- Stable device IDs are exchanged inside the pairing handshake, not advertised in mDNS.
- Pairing uses long-lived device keypairs and a six-digit verification code derived from the handshake transcript/public keys.
- Pairing sessions expire after roughly two to five minutes.
- Both devices must confirm the code.
- Both devices must approve the pre-merge preview before membership or sync events are written.
- Pre-merge preview should include device names/platforms, both idle status, settings-differ flag, preset counts, history counts, and history date ranges.

### Out of scope for the next pass unless explicitly reopened

- User-facing plaintext sync.
- Full authenticated session encryption implementation, unless the pass is explicitly expanded to pairing/security.
- Cloudflare relay transport.
- APNs.
- Android/Linux client implementations.
- Screen Time blocking.
- Manual IP pairing fallback.
