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

## Recommended Next Pass: LAN Pairing and Local Peer Sync Plan

The next pass should not jump directly to Cloudflare or APNs. The recommended next pass is to plan and implement **LAN-only peer pairing and anti-entropy sync** on top of the local event log.

### Goals

1. Add persistent device identity.
2. Add LAN-only pairing.
3. Add paired-device membership events.
4. Add local peer transport abstraction.
5. Add anti-entropy event exchange between paired devices.
6. Keep Cloudflare/APNs/crypto out until LAN sync semantics are proven.

### Proposed scope

#### Device identity

- Create a stable local `deviceId`.
- Store it in Keychain or another secure local identity store.
- Add a display device name.
- Do not add cloud identity/accounts.

#### Pairing v1

- LAN-only pairing.
- Both devices must be idle before pairing.
- Existing device chooses **Add Device**.
- New device chooses **Join Sync Group**.
- Devices discover each other on the local network.
- Both show the same six-digit verification code.
- User confirms the code on both devices.

#### Membership events

Add event types for:

- device paired
- device renamed
- device removed

Membership should be projected from the event log.

#### Anti-entropy sync

Implement peer catch-up by exchanging compact event summaries:

```text
deviceId -> latest sequence seen
```

Then peers request/send missing events.

Rules:

- Event imports are idempotent.
- Duplicate `eventID`s are ignored.
- Imported events are appended to the local event log.
- Projections rebuild from the merged event set.

#### UI

Add only the minimal UI needed for LAN pairing/status:

- Settings → Sync pane can be introduced in this pass.
- It should show:
  - sync mode: Off / LAN only
  - this device name
  - paired devices
  - Add Device
  - Join Sync Group
  - last seen / last sync status

Cloud Relay controls should remain hidden or explicitly unavailable until a later pass.

### Required planning before implementation

Before coding the next pass, create a focused plan for:

- local network permissions and Info.plist requirements
- sandbox/network entitlements, if any
- Bonjour/Network.framework service naming
- pairing message format
- membership event schema
- anti-entropy summary format
- conflict/correction notice behavior when imported events change visible timer state

### Verification expectations

- Unit tests for membership projection.
- Unit tests for event summary/missing-event calculation.
- Unit tests for idempotent event import.
- UI/state tests where practical for pairing disabled during active timer.
- CI-only build/test/sign/notarization validation.

### Out of scope for next pass

- Cloudflare KV mailbox.
- APNs.
- iOS/iPadOS app.
- Screen Time blocking.
- Multi-user/team sync.
- Multiple sync groups.
- Cryptographic revocation/key rotation.
