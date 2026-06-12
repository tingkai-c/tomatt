# Sync state is an immutable event log with projections

Accepted.

tomatt sync state will be represented by a generic replicated event log, with timer state, shared settings, history, membership, device lists, and sync status derived as projections. This keeps offline operation and anti-entropy reconciliation deterministic across devices, avoids rewriting history during conflict resolution, and lets losing conflict branches remain available for dedupe and consistency while normal projections ignore them.

Considered alternatives included syncing only current timer/settings records or physically rewriting/deleting conflicting history. Those options were rejected because they make offline merges harder to reason about and risk different devices deriving different state after reconnecting.
