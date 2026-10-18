# ADR 22: authenticated guest agent transport

Status: experimental evaluation; production pairing and Windows remain open.

The existing native Linux backend already creates a public virtio socket device.
Use that route for guest integration; it needs no guest NIC or host LAN service.
VZVirtioSocketConnection owns its descriptor. Retain the connection through every
asynchronous borrow and close through its owner. Native connect has no documented
deadline/cancellation; bound attempts and discard a late successful connection
after cancelling its caller rather than treating timeout as native completion.

Choose standard TLS 1.3 with mutual certificate authentication. The macOS host
uses Network.framework and Security identities; the Linux evaluator uses stock
OpenSSL with SSL_set_fd over AF_VSOCK. No invented handshake or SecureTransport
implementation. The latter is deprecated and lacks TLS 1.3. Network.framework
has no public connected-descriptor initializer, so evaluate TLS over a private
Unix endpoint and a ciphertext relay to the retained virtio descriptor. If Unix
TLS is unavailable, an explicitly selected app-owned loopback relay is a separate
option; never silently change transport or trust. The relay is not a trust anchor.

Both endpoints verify their enrolled peer, certificate purpose, validity and
scoped per-VM trust. The host also pins the exact peer certificate. Disable early
data; do not infer replay protection from a connected socket. Schema-generated
bounded typed messages negotiate version/features before health or integrations.
Session and request identifiers plus monotonic sequences reject stale messages.
Only health is advertised initially. Clipboard, files, shutdown, driver health,
seamless windows and authenticated installation remain distinct requirements.

Production private keys belong in Keychain on the host and protected guest agent
storage. Ad-hoc development signing does not establish authorized data-protection
Keychain access groups; controlled namespace/signing and enrollment are release
gates. The evaluation injects transient in-memory identities generated in a
private temporary directory, never source/logs/project files or generic media.
Unrelated VM boot must never query Keychain or depend on pairing availability.
Denied or locked credentials disable the dependent integration without reset or
trust weakening. No visible ready/setup control precedes actual verified health.

Acceptance: actual host/Linux TLS 1.3 over virtio socket, mutual rejection of
unknown peers, generated Swift/C cross-conformance, version/feature/sequence and
size limits, malformed/cancel/deadline/reconnect behavior, explicit key ownership,
no secret logs and normal guest shutdown. Public APIs and named host/guest/library
versions must accompany results. Windows service/session agent and signed setup,
production Keychain pairing, upgrades/rollback, minimum host and broad protocol
review remain open.
