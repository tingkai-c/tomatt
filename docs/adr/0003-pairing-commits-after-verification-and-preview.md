# Pairing commits only after verification and pre-merge approval

Accepted.

Pairing will not write membership events or import syncable events until both devices verify the transcript-derived six-digit code and approve the pre-merge preview. This makes failed or abandoned pairing attempts ephemeral, gives the user a final chance to review settings/history consequences, and prevents accidental permanent sync-group changes from nearby-device discovery or an incomplete handshake.

Considered alternatives included committing membership as soon as a WebSocket handshake succeeds or importing events before user approval. Those options were rejected because transport connectivity is not trust and because first-pairing history/settings merges are user-visible and hard to cleanly undo.
