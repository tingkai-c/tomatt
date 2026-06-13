# Sync Edge-Case Hardening Matrix

This matrix records G009 coverage for the usable multi-device LAN sync pass.

| Area | Expected behavior | Evidence |
| --- | --- | --- |
| Settings convergence | Offline setting edits from multiple origins converge through event-log import and shared projection. | `tomattTests/EventCoreTests.swift` `testTwoPeerCatchUpConvergesAndWatermarksReachTwo`; `tomattTests/AntiEntropySyncEngineTests.swift` `testTwoTrustedEncryptedPeersConvergeFromDivergentLogs`. |
| Preset convergence | Preset upsert, selection, order, delete, and default seed behavior replay deterministically. | `tomattTests/EventCoreTests.swift` `testSettingsAndPresetReplay`, `testPresetSelectionAndOrderReplay`, `testDeletingSelectedPresetFallsBackToFirstRemainingPreset`, `testLocalEventLogSeedsDefaultPresetsBeforeFirstMutation`. |
| Timer conflicts | Overlapping remote timer branches choose one visible branch deterministically; losing branches remain in raw history but are excluded from visible timer/stats. | `tomattTests/EventCoreTests.swift` distributed timer tests around overlap, tie-break, losing-branch exclusion, pause/resume, and terminal visibility. |
| Correction notice | Main timer UI receives only a non-blocking notice when visible timer state changes after sync; settings-only changes do not show a notice. | `TBTimerSyncCorrectionNoticeFactory` in `tomatt/EventCore.swift`; `TBTimer.publishSyncCorrectionNotice` and popover banner in `tomatt/Timer.swift`/`tomatt/View.swift`; `testCorrectionNoticeOnlyWhenVisibleTimerStateChanges`. |
| Local-only active timer restore | Active timer restore snapshots remain local-only and are not exported through anti-entropy. | `tomattTests/AntiEntropySyncEngineTests.swift` `testLocalOnlyActiveTimerSnapshotsAreNotExported`; `tomattTests/EventCoreTests.swift` active-session projection tests. |
| Multi-device relay | B re-exports retained A-origin signed events unchanged to C while A is offline; C verifies A's signature/key/membership. | `tomattTests/AntiEntropySyncEngineTests.swift` `testRelayReexportsOriginalSignedEventForOfflineOriginAndDuplicateImportIsIdempotent`. |
| Duplicate relay/import | Duplicate event IDs and duplicate relay paths are idempotent; origin/sequence collisions fail closed. | `tomattTests/EventCoreTests.swift` `testStrictImportDuplicateAndCollisionRules`; anti-entropy duplicate relay tests. |
| Backlog continuation | Large missing-event batches continue until drained without skipping watermarks. | `tomattTests/AntiEntropySyncEngineTests.swift` backlog continuation test. |
| Gaps/out-of-order | Out-of-order origin sequences do not advance contiguous watermarks incorrectly; later gap fill advances the watermark. | `tomattTests/EventCoreTests.swift` `testGapHandlingBuffersOutOfOrderEventsWithoutAdvancingWatermark`; `tomattTests/AntiEntropySyncEngineTests.swift` `testOutOfOrderGappedEventDoesNotAdvanceWatermarkIncorrectly`. |
| Removal | Removed peers are rejected for session context and runtime connect/sync; removal copy remains operational-only. | `tomattTests/SyncSessionSecurityTests.swift` removed-peer test; `tomattTests/SyncRuntimeCoordinatorTests.swift` `testRemovedPeerCannotConnectOrSync`; `tomatt/SyncUI/SyncSettingsModel.swift` `removeDeviceCopy`. |
| Manual IP/Tailscale | Manual address pairing accepts LAN IP, Tailscale host, or hostname and uses the same Pair Device verification/encryption path. | `tomattTests/LANTransportTests.swift` manual endpoint tests; `tomattTests/SyncSettingsModelTests.swift` manual Pair by Address tests; `docs/adr/0008-manual-address-pairing-and-lan-runtime-port.md`. |
| Port unavailable/fallback | Default listener port is `40484`; unavailable port surfaces a runtime error/status and Settings exposes override guidance. | `tomattTests/LANTransportTests.swift` default/override and port-unavailable tests; `tomattTests/SyncSettingsModelTests.swift` port copy/validation. |
| Bonjour privacy | Discovery TXT is minimal and does not include stable device ID, signing fingerprint, or display name. | `tomattTests/LANTransportTests.swift` TXT metadata tests; `docs/adr/0008-manual-address-pairing-and-lan-runtime-port.md`. |
| Sync Off | Off stops advertise, browse, listen, heartbeat, reconnect state, and status. | `tomattTests/LANTransportTests.swift` start/stop runtime test; `tomattTests/SyncRuntimeCoordinatorTests.swift` `testOffStopsLANAndReconnectAttempts`. |
| Cloud Relay | Cloud Relay remains disabled/future/unavailable and has no active runtime path. | `tomattTests/SyncSettingsModelTests.swift` Cloud Relay tests; `tomattTests/SyncRuntimeCoordinatorTests.swift` `testCloudRelayModeDoesNotStartCloudPathButRecordsUnavailableAndCanStartLAN`. |

## Residual Risk Before CI

Local verification is intentionally static/non-build per repository policy. GitHub Actions remains the build, signing, notarization, packaging, and artifact authority.
