# LAN sync uses mDNS, WebSocket, and Protobuf

Accepted.

tomatt's sync protocol is intended for cross-platform personal-device sync, not only Apple-to-Apple sync. LAN discovery will use standards-based mDNS/DNS-SD, LAN sessions will use WebSocket connections, and wire messages will use Protobuf binary frames so future macOS, iOS/iPadOS, Android, Linux, and other clients can share the same protocol while using native platform networking libraries.

Considered alternatives included MultipeerConnectivity, raw TCP length-prefixed Protobuf, HTTP REST endpoints, and gRPC. MultipeerConnectivity was rejected because it is Apple-only. Raw TCP was rejected in favor of WebSocket because WebSocket keeps persistent bidirectional communication while improving cross-platform library support and debugging ergonomics. HTTP REST was rejected because live timer sync needs bidirectional low-latency updates. gRPC was rejected as heavier and less natural for symmetric local peer sessions.

The protocol remains layered: mDNS and WebSocket are LAN/session concerns, while reusable SyncCore messages such as event summaries, missing-event requests, event batches, and acknowledgements should stay transport-independent so they can be reused by a future Cloud Relay transport.
