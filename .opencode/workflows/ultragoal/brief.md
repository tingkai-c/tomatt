# Ultragoal Brief: Complete Usable Multi-Device LAN Sync

Implement complete user-facing LAN sync for tomatt across multiple paired personal devices using the approved ralplan.

## Aggregate Objective

Deliver usable multi-device LAN sync for tomatt with Bonjour discovery, manual IP/Tailscale pairing, verified secure pairing, durable signed-event retention, multi-origin relay, live anti-entropy, operational removal, runtime status, Settings UI productization, exhaustive edge-case coverage, and GitHub Actions artifact delivery.

## In Scope

- Sync modes: Off and LAN only. Cloud Relay remains disabled/future.
- One user-facing **Pair Device…** action, with internal Add/Join protocol roles hidden from top-level UI.
- Nearby Bonjour discovery and **Pair by Address…** for manual IP/Tailscale.
- Default listener/manual port `40484`, with advanced override and port-unavailable status.
- Verified pairing: both devices idle, transcript-derived six-digit code, pre-merge preview, settings-source choice, and no durable trust/import before approval.
- Multi-device sync from the start, including A/B/C relay while A is offline.
- Durable original **Signed Sync Event** retention so relays preserve original signer/authorship.
- Multi-origin anti-entropy summaries, missing-event requests, batches, acknowledgements, backlog, gaps, and duplicate handling.
- Operational-only device removal with membership interval validation; no cryptographic revocation/key rotation claim.
- Keychain-backed private signing keys and sync secrets.
- App-support/event-adjacent public trust, group, and signed-event metadata.
- Reset Sync: turn sync off, clear sync metadata, keep local history/events, require re-pair.
- Runtime coordinator for mode lifecycle, peer states, sync triggers, errors, and status.
- Settings → Sync productization with device rows, statuses, Pair Device flow, manual address, reset/remove, and local-network copy.
- Main timer UI limited to non-blocking correction notices.
- Documentation/ADR/status updates for signed relay, manual address/Tailscale, runtime/reset, and changed v1 scope.

## Constraints

- Keep `SyncCore` independent of SwiftProtobuf, Network/WebSocket/mDNS, SwiftUI/AppKit, LANTransport, and SyncUI.
- LAN transport moves frames and connection state only; it must not import events or decide trust.
- Manual IP/Tailscale reachability does not bypass verification, encryption, signed import, membership validation, or preview approval.
- Bonjour TXT must not expose stable device IDs or signing fingerprints; use ephemeral discovery IDs.
- Sync Off means no advertising, browsing, listening, connecting, heartbeat, or reconnect attempts.
- Protobuf changes must be additive and compatibility-preserving.
- Cloud Relay must remain unavailable/future and non-selectable.
- Device removal v1 is operational only; UI/docs must not imply cryptographic erasure, revocation, or key rotation.
- Do not run local Xcode builds, local signing, notarization, packaging, or local artifact builds.
- Do not materially edit `.github/workflows/main.yml` unless GitHub Actions logs for the exact commit prove a workflow defect.
- Final delivery must follow the repository CI artifact install loop.

## Critical Edge Cases

- A/B/C relay with A offline: B relays A-origin signed events unchanged; C verifies A, not B.
- Out-of-order gaps and contiguous per-origin watermarks.
- Duplicate events through multiple relay paths.
- Origin/sequence collisions.
- Unknown signer/key mismatch/signer mismatch.
- Device removal before/after event validity.
- Removed device reconnect after removal known.
- Delayed removal knowledge under operational-only v1.
- Device reinstall/key loss requiring reset/re-pair.
- Simultaneous duplicate connections.
- Offline backlog and large batch continuation.
- Settings/preset convergence.
- Timer conflict convergence and non-blocking correction notice.
- Bonjour unavailable but manual IP/Tailscale pairing works.
- Port `40484` unavailable and advanced override works.

## Completion Gate

Do not mark the aggregate goal complete until all non-superseded goals are complete, final cleanup/review passes, independent code review approves, architecture-sensitive review is clear, exact-commit GitHub Actions tests/build/sign/notarization succeed, the CI artifact is downloaded and verified to contain `tomatt.app`, the app is installed to `/Applications/tomatt.app`, and the installed app launches.
