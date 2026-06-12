# Ultragoal Brief: Cross-Platform LAN Sync

Implement tomatt v1 cross-platform LAN sync for one user's personal devices using the approved ralplan.

## Aggregate Objective

Deliver LAN-based personal-device sync for tomatt with a cross-platform protocol, verified pairing, authenticated encrypted sessions, trusted signed-event import, deterministic timer conflict projection, live anti-entropy, and Settings → Sync productization.

## In Scope

- Protobuf schema under `proto/tomatt/sync/v1` with package `tomatt.sync.v1`.
- Swift generated/wire adapter layer that does not infect `SyncCore`.
- Platform-neutral SyncCore façade and domain/protocol mappers over existing event-log primitives.
- Security/trust model with long-lived device signing identity, sync-group key lifecycle, signed events/envelopes, and trusted import boundary.
- Internal-only LAN mDNS/WebSocket transport skeleton using `_tomatt-sync._tcp`, `/tomatt-sync`, and `tomatt.sync.v1.protobuf`.
- Verified LAN pairing with transcript-derived six-digit code, idle gates, expiration, pre-merge preview, settings-source choice, and staged all-or-nothing commit.
- Authenticated encrypted LAN sessions/messages before any user-facing sync claim.
- Deterministic distributed timer conflict projection before live timer sync.
- Live anti-entropy sync between trusted paired devices.
- Settings → Sync UI, local-network permission timing/copy, paired device list/status, Add/Join, and remove/unpair.
- Documentation/status updates and repository delivery loop.

## Constraints

- Do not expose stable `deviceId` in mDNS.
- Plaintext transport is allowed only for internal milestones and must not be presented as completed user-facing sync.
- Do not allow LAN transport to call raw `TBLocalEventLog.importEvents` directly; trusted import must verify authenticated session context, membership/removal policy, and event/envelope signature first.
- Do not write permanent membership, trusted-peer, sync-group key, or imported syncable event state until both pairing code confirmation and pre-merge approval succeed.
- Keep `SyncCore` independent of SwiftProtobuf, SwiftNIO, mDNS, WebSocket, and SwiftUI/AppKit UI.
- Keep Cloud Relay hidden, disabled, or clearly future/unavailable until separately implemented.
- Do not run local Xcode builds, local signing, notarization, packaging, or local artifact builds.
- Do not materially edit `.github/workflows/main.yml` unless GitHub Actions logs for the exact commit prove a workflow defect.
- Final delivery must follow the repository CI artifact install loop.

## Security Checkpoints

- Long-lived device private keys and sync-group keys live in Keychain.
- Ephemeral pairing/session X25519 private keys, transcript nonces, and AEAD counters live in memory only and are destroyed on cancel, timeout, or session close.
- No session resumption is in scope unless separately reviewed.
- Event/envelope signing must have schema docs and deterministic test vectors before trusted import ships.
- v1 device removal is operational only; no group-key rotation or cryptographic revocation claim.

## Completion Gate

Do not mark the aggregate goal complete unless authenticated encrypted sessions, signed-event trusted import, verified pairing, deterministic timer conflict projection, live anti-entropy, Settings → Sync productization, independent review, CI success, artifact install, and app launch all pass.
