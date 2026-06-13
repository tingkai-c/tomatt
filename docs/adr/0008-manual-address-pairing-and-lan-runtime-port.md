# ADR 0008: Manual Address Pairing and LAN Runtime Port

## Status

Accepted for the complete usable LAN sync pass.

## Decision

tomatt will expose one user-facing **Pair Device…** flow. The flow offers nearby Bonjour-discovered devices and **Pair by Address…** for manual LAN, private-overlay, or Tailscale reachability.

Manual pairing uses the same WebSocket endpoint, Protobuf frames, verified pairing transcript, encryption, pre-merge preview, signed trusted import, and membership validation as Bonjour pairing. Entering an address replaces discovery only; it does not establish trust.

The default listener/manual pairing port is `40484`. If that port is unavailable, tomatt will surface an actionable port-unavailable state and allow an advanced override. Bonjour advertises the actual active port. Manual pairing uses the default port unless the user provides an override.

## Alternatives Considered

- Bonjour-only v1: rejected because manual IP/Tailscale support is now a product requirement and mDNS can fail on real networks.
- Manual address as a hidden/debug-only flow: rejected because Tailscale/private-overlay pairing is user-facing scope.
- Ephemeral port only: rejected because manual/Tailscale pairing is painful when the port changes every launch.
- Separate Add Device / Join Sync Group top-level actions: rejected as user-facing protocol leakage. Internal pairing roles may remain for deterministic transcripts.

## Consequences

- Existing design docs that said no manual IP/host fallback in v1 are superseded.
- LAN transport needs a stable default port constant and override model.
- Settings and pairing UI need host/port validation and clear timeout/refused/wrong-service errors.
- Security copy must be clear that Tailscale/manual reachability does not bypass tomatt's own verification and trust checks.
