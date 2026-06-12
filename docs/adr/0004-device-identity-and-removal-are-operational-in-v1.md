# Device identity uses long-lived keys and removal is operational in v1

Accepted.

Paired devices will have long-lived device identities backed by device keypairs, and future sessions will authenticate against trusted peer public keys established during verified pairing. Removing a device in v1 stops local sync, stops accepting or initiating connections with that device, and propagates a membership removal where possible, but it does not provide cryptographic revocation, group-key rotation, or forward secrecy against a previously paired device.

This deliberately separates v1 operational safety from stronger revocation semantics. Cryptographic revocation/key rotation was rejected for v1 because it would substantially expand the protocol, recovery, and failure-mode surface before the basic personal-device sync model is proven.
