# tomatt

tomatt is a personal timer app whose sync domain coordinates one shared timer and its related settings, history, and device membership across a user's own devices.

## Language

**Cross-platform personal-device sync**:
Sync for one user's own devices across supported operating systems, including macOS now and possible future iOS/iPadOS, Android, Linux, and other clients.
_Avoid_: Apple-only sync, team sync, multi-user sync

**Platform-neutral sync protocol**:
A tomatt sync protocol whose message semantics are independent of any one operating system, while each platform may implement it using native discovery and networking libraries.
_Avoid_: Apple-only protocol, shared networking library requirement

**Sync Group**:
The set of the user's paired devices that share one timer, shared settings, history, and membership metadata.
_Avoid_: Account, workspace, team

**Paired Device**:
A device identity that the user has explicitly trusted to participate in their sync group.
_Avoid_: Nearby device, connected peer

**Device Identity**:
The stable identity of one app install on one device, used to distinguish who created sync events and which devices are trusted.
_Avoid_: Account, user, session
