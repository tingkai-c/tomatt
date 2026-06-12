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

Status: **implemented locally; awaiting CI delivery when committed/pushed**

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
