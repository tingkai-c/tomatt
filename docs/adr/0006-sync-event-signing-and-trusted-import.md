# ADR 0006: Sync Event Signing and Trusted Import

## Status

Accepted for G003.

## Decision

- Model display/device identity separately from cryptographic sync identity.
- Use CryptoKit `Curve25519.Signing` (Ed25519) for production event signatures on supported Apple platforms.
- Keep long-lived device signing keys and sync-group secrets behind storage protocols; tests use in-memory stores.
- Sign an interim v1 deterministic sorted-key JSON canonical envelope that includes creator device id, device sequence, schema version, event id, event type, recorded timestamp, and the SHA-256 of domain payload bytes.
- Exclude transport/session metadata from signed bytes.
- Require trusted peer membership, non-removal, deterministic event structure, and signature verification before raw event-log import.

## Consequences

- No LAN transport, pairing, encrypted session, or revocation behavior is implied by G003.
- v1 removal is an operational import rejection policy only; it is not cryptographic revocation or key rotation.
- Canonical JSON is an interim compatibility surface pending final protobuf event payload modeling.
