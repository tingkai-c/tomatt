# Sync Design Decisions

This document records the product and architecture decisions made for tomatt's future sync feature.

## Product Model

- tomatt will present sync as **one shared timer across the user's personal devices**.
- Devices may be Mac, iPhone, or iPad, but all devices are peers in the sync model.
- The feature is for **personal device sync**, not multi-user or team collaboration.
- Version 1 supports exactly **one sync group per app install**.
- A sync group supports exactly **one active shared timer**.
- Pairing establishes long-lived trust between device identities; transports do not define the relationship.

## Platform Architecture

- `TimerCore` and `SyncCore` should be platform-neutral.
- Platform-specific apps provide their own UI and OS integrations.
- Platform-specific concerns include menu bar UI, notifications, APNs registration, Screen Time, local-network permission prompts, and settings windows.
- `SyncCore` should define protocols for persistence, networking, identity, crypto, clock, and logging rather than depending on concrete implementations.

## Data Model

- Synced domains use a single generic replicated event log.
- The local event log is the source of truth for synced timer state, shared settings, history, and membership metadata.
- Current timer state, shared settings, stats, device lists, and sync status are projections derived from the event log.
- The local event log is immutable: events are not physically rewritten or deleted during reconciliation.
- Local event logs are kept forever in v1; no local compaction or snapshotting is required initially.
- Local event logs do not need separate at-rest encryption in v1.
- Old pre-sync stats/settings do not need migration. The new event-log-backed data becomes the normal app data.

## Event Identity and Ordering

- Each device has a stable `deviceId`.
- Each device emits monotonically increasing `deviceSequence` values.
- `eventId` is derived from `deviceId + deviceSequence`.
- Events include `createdAt` wall-clock timestamps for timer math and UX/history.
- Cross-device conflicts are resolved by domain rules, not by a global sequence number.
- Events or envelopes are signed by the creating device's private key.

## Timer Semantics

- Any paired device may start, pause, resume, skip, stop, or complete the shared timer.
- Timer controls are optimistic: actions apply locally immediately, then sync outward.
- Work and rest intervals can both be paused/resumed.
- Rest intervals are mandatory parts of the shared workflow; skipping or deferring rest is a shared timer event.
- `Stop`, `Skip`, and natural `Complete` are distinct timer events.
- Automatic transitions are represented as explicit events, for example:
  - `timer.completed(workSessionId)`
  - `timer.started(restSessionId)`
- Each work, short-rest, and long-rest interval has its own `sessionId`.
- Timer/history events include `setId` and `workIntervalIndex`.
- `setId` resets after a completed/skipped long rest or when starting a new work sequence from idle.
- Shared setting changes affect future sessions only; active sessions keep their preset snapshot.

## Offline and Conflict Behavior

- The app must remain fully usable offline.
- Devices can create local timer events while offline.
- A timer branch is the set of events for one `sessionId`.
- If active timer branches overlap, the branch with the earliest start event wins.
- Losing overlapping branches remain in the immutable event log for dedupe/consistency, but normal projections ignore them.
- Losing branches are not shown in normal stats/history.
- Losing events still propagate to peers so all devices can deterministically derive the same projection.
- If reconciliation changes visible timer state, show a small notice: `Timer updated after syncing with [Device Name].`
- The correction notice should be transient, non-scary, and auto-dismiss after about four seconds.

## Shared Settings

Shared settings in v1:

- work duration
- short rest duration
- long rest duration
- work intervals per set
- named presets
- pause-after-rest-finish
- extend-work-after-finish

Device-local settings in v1:

- keyboard shortcuts
- launch at login
- notification permission/status
- APNs registration status
- Screen Time permission/status
- sound output/volume
- appearance mode
- local menu-bar behavior

Merge rule:

- Latest setting change wins per setting key.
- Different setting keys merge independently.

## History and Stats

- History is global per sync group.
- History is append-only in v1.
- History dedupes by `sessionId`.
- Synced history includes work/rest sessions and completion outcomes such as completed, skipped, stopped, and abandoned, plus duration/overtime fields consistent with current stats semantics.
- Existing histories on newly paired devices are merged into the shared sync-group history, deduped by `sessionId`.
- First pairing should show a confirmation summary before merging histories.

## Pairing

- Pairing v1 is LAN-only.
- Pairing requires both devices to be idle.
- All non-idle timer states block pairing, including running, paused, pending, overtime/extended, or break-transition states.
- Pairing flow:
  1. Existing device chooses **Add Device**.
  2. New device chooses **Join Sync Group**.
  3. Nearby devices appear through LAN discovery.
  4. User selects the device.
  5. Both devices show the same six-digit verification code.
  6. User confirms the code on both devices.
  7. Devices exchange identity and sync-group information.
- No manual IP pairing fallback in v1.
- If shared settings differ during first pairing, the user chooses which device's settings become initial shared settings.

## LAN Sync

- LAN sync uses local discovery and direct peer connections.
- Bonjour/Network.framework-style discovery is expected.
- LAN transport should keep persistent-ish connections open while peers are reachable, with reconnect/backoff.
- SyncCore remains transport-agnostic.
- Devices perform anti-entropy sync by exchanging compact event summaries, such as latest sequence per device, and then exchanging missing events.

## Cloud Relay

- Cloud Relay is optional.
- Sync modes:
  - Off / local only
  - LAN only
  - LAN + Cloud Relay
- Cloud Relay uses Cloudflare Workers plus KV as a lightweight encrypted mailbox.
- Both deployment models are supported:
  - official tomatt relay
  - custom/self-hosted Cloudflare Worker URL
- A sync group has exactly one active Cloud Relay endpoint.
- Relay endpoint changes affect future cloud delivery only; mailbox migration is not required.
- LAN/peer anti-entropy fills gaps where possible.

### Cloudflare KV Mailbox

- KV stores encrypted group broadcast envelopes, not readable sync data.
- KV envelope metadata may include group ID, sender device ID, sequence range, creation time, expiry time, and ciphertext.
- Cloudflare stores encrypted envelopes for 30 days.
- Permanent truth remains on devices.
- If a device has been offline longer than the mailbox TTL, it must direct-sync with another paired device that has the permanent local event log.
- Cloudflare should not own merge, conflict resolution, membership truth, or timer state.
- Cloudflare validates request metadata/rate/size/auth enough to prevent abuse, but devices decrypt and validate event contents.

### APNs

- APNs is used for silent/background wake-up hints.
- APNs sync pushes are not visible user notifications.
- APNs tokens are synced through membership metadata events.
- The Worker receives target APNs tokens from the sending device and does not need a token registry in v1.
- APNs provider credentials live in Worker secrets.

## Security

- Sync envelopes are end-to-end encrypted between paired devices.
- v1 uses a shared sync-group key for group broadcast envelopes.
- Device private keys and sync group keys live in Keychain.
- Cloudflare mailbox requests require group authentication.
- There is no cryptographic revocation/key rotation in v1.
- Removing a device stops operational sync, but v1 does not guarantee cryptographic forward secrecy against a previously paired device.

## UI Decisions

### Settings -> Sync

Settings should expose:

- sync mode: Off / LAN only / LAN + Cloud Relay
- this device name
- paired devices list with name, platform, last seen, connection status, and remove/unpair action
- Add Device
- Cloud Relay configuration:
  - official/custom relay choice
  - custom URL field
  - Test Connection
  - connected/failed/retrying status
- last sync/retry status
- copy explaining that sync data is end-to-end encrypted before upload

### Main Timer Surface

- Keep the main timer UI simple.
- Do not show routine sync mechanics.
- Show only transient correction/problem notices when sync changes visible timer state.

## Permission Prompts

- Ask for local network permission when entering sync setup or pairing.
- Ask for notifications/APNs permission when enabling Cloud Relay/background wakeups.
- Ask for Screen Time permission later, only when enabling mobile blocking.

## Mobile Screen Time

- Screen Time blocking is out of scope for v1.
- Long term, mobile Screen Time shielding is a local side effect derived from the shared timer projection.
- Screen Time permission/status and enforcement state are not synced as domain events.
- If a mobile device misses a pause/stop/resume correction, it continues enforcing the last known valid schedule until the planned end, then adjusts when sync catches up.

## Explicitly Out of Scope for v1

- iOS/iPadOS app implementation
- Screen Time blocking
- Cloud Relay pairing
- manual IP pairing
- multi-user/team timers
- multiple sync groups
- historical edit/delete
- cryptographic revocation/key rotation
- local event-log encryption
- per-category sync toggles
- conflict resolution UI beyond the transient correction notice
