# ADR 0007: Signed Event Retention and Multi-Origin Relay

## Status

Accepted for the complete usable LAN sync pass.

## Decision

tomatt will retain each accepted syncable event's original `TBSignedSyncEvent` metadata in a durable event-adjacent sidecar store. The raw local event log remains the domain source of truth for projections, while the signed-event store is the source of truth for re-exporting imported events to other paired devices.

Anti-entropy sync will operate across all trusted origin devices, not only the local signer. When device B relays an A-origin event to device C, B must send A's original signed event unchanged. C verifies A's signature, key fingerprint, event structure, and membership validity. B is validated only as the authenticated transport peer for that session; B does not become the event author.

## Membership Validity

Membership is event-sourced. A device's sync events are valid only during that device's active membership interval in the Sync Group. Canonical membership ordering is derived from the same deterministic sync-event ordering used for projection: replicated origin identity, `deviceSequence`, event ID, and the existing projection tie-breakers as needed. Wall-clock timestamps are not the validity cutoff.

Events ordered before a removal event may remain valid. Events ordered after a removal event are rejected for import and relay. If a device has not yet learned a removal, operational-only v1 may temporarily accept based on its local membership view; after learning the removal, post-removal events from that origin must stop being treated as valid for future relay/projection. This is operational removal only, not cryptographic revocation.

## Alternatives Considered

- Embedding signatures directly into `TBEventEnvelope`: rejected for v1 because it would mix security/relay metadata into the raw domain event log and broaden migration risk.
- Re-signing relayed events as the relay device: rejected because it loses original authorship and prevents receivers from verifying the true origin device.
- Peer-local summaries only: rejected because B could not tell C about A-origin events while A is offline.

## Consequences

- A new durable signed-event store is required before multi-origin relay can be enabled.
- Raw event import and signed metadata retention need one logical transaction or a safe non-relayable/quarantine state on partial failure.
- Trusted import must distinguish authenticated transport peer validation from original signer/origin validation.
- A/B/C relay, removal validity, duplicate relay, out-of-order gaps, and origin/sequence collision tests are required before user-facing sync is complete.
