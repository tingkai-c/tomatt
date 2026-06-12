# Ultragoal Brief: Local Event-Log Cutover

Implement the first local-only event-log architecture for tomatt.

## In Scope

- Add platform-neutral local event models, append-only JSONL event store, and projections.
- Event-source shared timer settings and presets from the start.
- Ignore legacy AppStorage/settings/preset/stat data without deleting it.
- Discard legacy `activeTimerSession`; restore only from the new event log.
- Preserve existing timer edge behaviors.
- Keep LAN, Cloudflare, APNs, crypto, and Settings → Sync out of this implementation.

## Constraints

- Do not run local Xcode builds, local `xcodebuild`, signing, notarization, or packaging.
- Do not edit `.github/workflows/main.yml` unless CI logs prove a workflow defect.
- Local verification is static/non-build only.
- Final delivery must follow repository CI artifact install loop.
