# v1 sync is one personal sync group with one shared timer

Accepted.

tomatt v1 sync is for one user's personal devices, with exactly one sync group per app install and one active shared timer in that group. Multi-user collaboration, multiple groups, and multiple concurrent shared timers are out of scope so the first sync design can focus on local-first device pairing, deterministic timer reconciliation, shared settings, and history merge behavior.

Considered alternatives included team timers and multiple independent sync groups. Those options were rejected for v1 because they introduce permissions, ownership, invitations, group selection, and more complex conflict semantics that are not necessary for personal cross-device timer continuity.
