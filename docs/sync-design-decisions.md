# Sync Design Decisions

This document records the product and architecture decisions made for tomatt's future sync feature.

## Product Model

- tomatt will present sync as **one shared timer across the user's personal devices**.
- tomatt's sync protocol is for **cross-platform personal-device sync**. Devices may be macOS, iOS/iPadOS, Android, Linux, or other future clients, but all devices are peers in the sync model.
- The feature is for **personal device sync**, not multi-user or team collaboration.
- Version 1 supports exactly **one sync group per app install**.
- A sync group supports exactly **one active shared timer**.
- Pairing establishes long-lived trust between device identities; transports do not define the relationship.

## Platform Architecture

- `TimerCore`, `SyncCore`, and the sync wire protocol should be platform-neutral.
- Platform-specific apps provide their own UI and OS integrations.
- Platform-specific concerns include menu bar UI, notifications, APNs registration, Screen Time, local-network permission prompts, and settings windows.
- `SyncCore` should define protocols for persistence, networking, identity, crypto, clock, and logging rather than depending on concrete implementations.
- Platform implementations may use native libraries to implement the same protocol, for example Network.framework/SwiftNIO on Apple platforms, Android NSD plus a WebSocket library, and Avahi plus a WebSocket library on Linux.

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
- Nearby devices may appear in pairing UI while a timer is non-idle, but pairing handshake start and final confirmation require both devices to be idle.
- Pairing discovery uses mDNS/DNS-SD and WebSocket session messages; stable device IDs are exchanged only inside the pairing handshake, not in mDNS advertisements.
- Pairing is symmetric: both devices advertise/listen during pairing, and the device where the user selects the peer may initiate the WebSocket connection.
- The six-digit verification code is derived from the pairing handshake transcript and exchanged public keys, not randomly generated by one side.
- Pairing sessions expire after a short window, roughly two to five minutes.
- Pairing flow:
  1. Existing device chooses **Add Device**.
  2. New device chooses **Join Sync Group**.
  3. Nearby devices appear through LAN discovery.
  4. User selects the device.
  5. Devices establish a WebSocket session and exchange pairing handshake metadata.
  6. Both devices show the same transcript-derived six-digit verification code.
  7. User confirms the code on both devices.
  8. Devices show a pre-merge preview before importing events.
  9. User approves the merge preview and settings-source choice on both devices.
  10. Devices exchange identity, sync-group information, membership events, and syncable events.
- No manual IP pairing fallback in v1.
- If shared settings differ during first pairing, the user chooses which device's settings become initial shared settings.
- The pre-merge preview shows device names/platforms, both idle status, whether shared settings differ, preset counts, history session counts, and history date ranges.
- The preview does not need to show an exact session list in v1.
- History always merges after successful pairing confirmation, deduped by session/event identity.
- No membership events or syncable events are written to the permanent event log until code verification and merge approval both succeed.

## LAN Sync

- LAN sync uses local discovery and direct peer connections.
- LAN discovery uses standards-based mDNS/DNS-SD with service type `_tomatt-sync._tcp` so Apple, Android, Linux, and other future clients can discover each other on multicast-capable local networks.
- LAN transport uses WebSocket connections carrying Protobuf binary messages.
- User builds expose only the sync WebSocket endpoint; debug/health HTTP endpoints may exist only in developer builds or behind explicit debug flags.
- The WebSocket endpoint path is `/tomatt-sync`.
- The WebSocket subprotocol is `tomatt.sync.v1.protobuf`; the subprotocol names the major protocol version, while minor versions and capabilities are negotiated in the `Hello` message.
- Each active client runs a local WebSocket listener and advertises it through mDNS while pairing/setup discovery is active or while LAN sync is enabled and the app is reachable.
- WebSocket frames carry exactly one top-level Protobuf message envelope.
- User-facing sync requires a verified paired device and authenticated encrypted sessions/messages. Plaintext `ws://` Protobuf transport is allowed only for internal development milestones that are not presented as completed user-facing sync.
- LAN transport should keep persistent-ish connections open while peers are reachable, with application-level heartbeat, reconnect, exponential backoff with jitter, and deterministic duplicate-connection resolution.
- Heartbeats use application-level `Ping`/`Pong` messages; native WebSocket ping/pong may also be used when the platform library makes it practical.
- Devices perform anti-entropy sync by exchanging compact event summaries, such as latest contiguous sequence per device, and then exchanging missing events.
- A paired/trusted connection runs anti-entropy after the version/capability and authentication handshakes complete.
- Devices may push a lightweight "new events available" message after appending local syncable events so peers can request summaries/missing events.
- `SyncCore` remains transport-agnostic; LAN transport calls SyncCore APIs rather than owning merge or projection behavior.

### LAN Discovery Privacy

- mDNS TXT records expose only minimal compatibility/routing metadata:
  - `proto=tomatt-sync`
  - `v=1`
  - `transport=ws`
  - `encoding=protobuf`
  - `disc=<ephemeral discovery id>`
- Stable `deviceId` values are not advertised through mDNS.
- During explicit pairing/setup discovery, the service instance name may include the user-visible device display name to make nearby-device selection easier.
- Outside pairing/setup mode, advertisements should use a generic instance name plus ephemeral discovery ID.
- Detailed capabilities are exchanged in the WebSocket `Hello` message, not in mDNS TXT records.
- No manual IP/host fallback is provided in v1; it may be reconsidered later for diagnostics or if real-world mDNS failures require it.

### LAN Connection Behavior

- Discovery uses a hybrid model:
  - broad browse/advertise behavior during pairing/setup
  - opportunistic reconnect for already paired devices while LAN sync is enabled and the app is active/reachable
- Either side may initiate the outbound WebSocket connection after discovery.
- If both peers connect simultaneously, keep one connection by deterministic device-ID ordering after stable identity is revealed/verified; temporary duplicate connections may exist before that point.
- Initial reconnect delay should start around one second and back off exponentially to roughly one minute with jitter.
- Reconnection continues while LAN sync is enabled and the app is active/reachable, and stops when sync mode is Off or the peer is removed.
- macOS should sync while the menu-bar app is running; mobile background LAN behavior is best-effort and platform-constrained.

### LAN Protocol Messages

- Protobuf schemas live in this repository initially, under a path such as `proto/tomatt/sync/v1/tomatt_sync.proto`. They may be extracted to a separate protocol repository when a second client exists.
- The Protobuf package is `tomatt.sync.v1`.
- Breaking protocol changes use a new package/version such as `tomatt.sync.v2`; non-breaking additions remain in v1 and follow Protobuf compatibility discipline.
- Removed fields reserve their field numbers/names and field numbers are never reused.
- Protocol timestamps use `google.protobuf.Timestamp`.
- UUID-like identifiers use canonical lowercase UUID strings in v1.
- Protocol durations use integer seconds, including settings durations even if a client stores or displays those values in minutes.
- The wire protocol uses a top-level message envelope with message ID, optional response/correlation ID, sent timestamp, semantic protocol major/minor version where appropriate, and a `oneof` payload.
- The protocol has a session layer for LAN/session concerns such as `Hello`, `Ping`, `Pong`, pairing messages, capability negotiation, and errors.
- The protocol has a sync layer for transport-independent messages such as event summaries, missing-event requests, event batches, event-batch acknowledgements, and new-events-available notifications.
- `Hello` includes protocol major/minor version, app version/build, platform, display name where appropriate, and capabilities.
- Peers require matching protocol major version; minor-version differences are allowed when required capabilities overlap.
- Unknown optional capabilities are ignored; missing required capabilities reject the session.
- Protocol errors use typed machine-readable codes plus optional human-readable detail, including `UNSUPPORTED_VERSION`, `UNPAIRED_DEVICE`, `PAIRING_NOT_IDLE`, `BAD_MESSAGE`, `IMPORT_REJECTED`, and `INTERNAL_ERROR`.
- User builds reject non-Protobuf/text WebSocket frames.
- A conservative maximum message size should be specified before live transport ships; compression and chunking are deferred until needed.

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
- LAN sessions use pairwise authenticated encryption between paired devices, while shared sync-group encryption remains the model for stored/broadcast envelopes and future relay delivery.
- Pairing uses long-lived device keypairs. Public keys are exchanged during verified pairing, trusted peer public keys are stored, and future sessions are authenticated against those trusted keys.
- Device private keys and sync group keys live in Keychain.
- Non-Apple clients should use platform secure storage where available, such as Android Keystore or Linux Secret Service/libsecret, with any weaker fallback documented explicitly.
- Cloudflare mailbox requests require group authentication.
- There is no cryptographic revocation/key rotation in v1.
- Removing a device stops operational sync immediately, emits/propagates a membership removal where possible, and stops accepting/initiating connections with that device, but v1 does not guarantee cryptographic revocation or forward secrecy against a previously paired device.

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
- Android app implementation
- Linux app implementation
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
