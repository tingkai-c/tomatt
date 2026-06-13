# ADR 0009: Sync Runtime Status and Reset

## Status

Accepted for the complete usable LAN sync pass.

## Decision

tomatt will add a sync runtime coordinator that owns LAN sync mode lifecycle, storage/security health, peer status, connection attempts, anti-entropy triggers, and Settings-visible status. `SyncCore` remains transport-, wire-, and UI-free.

When Sync is Off, tomatt performs no LAN sync activity: no advertising, browsing, listening, connecting, heartbeats, or reconnect attempts. When LAN only is enabled and storage/security health is ready, tomatt may advertise, browse, listen, connect to paired devices, and sync automatically.

Reset Sync turns sync off, clears local sync metadata such as trusted peers, sync-group metadata, signed-event sidecar metadata, and runtime pairing state, but preserves the raw local event/history log. After reset, the device must pair again. If private keys or sync secrets are missing or corrupt, tomatt disables LAN sync and offers reset/re-pair instead of silently claiming old pairings still work.

## Alternatives Considered

- Let UI screens directly start/stop transport: rejected because mode lifecycle and peer state need one coordinator to avoid background activity leaks.
- Delete local history on reset: rejected because Reset Sync is a trust/network reset, not a data wipe.
- Silently regenerate keys while preserving old pairings: rejected because old peers would no longer authenticate reliably and the UI would misrepresent trust.

## Consequences

- Settings → Sync must show health/status states such as Off, starting, searching, syncing, up to date, offline, retry scheduled, permission denied, error, reset required, and removed.
- Runtime tests must prove Off tears down all LAN activity.
- Cloud Relay remains disabled/future and has no active runtime path in this pass.
