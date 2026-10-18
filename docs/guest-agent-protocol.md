# Guest protocol — experimental health transport

The first native host/Linux transport (private development record omitted)
uses standard TLS 1.3 mutual authentication and schema-generated typed messages.
It is a health-only evaluator with transient identities. The
installed Alpine/OpenRC evaluation (private development record omitted)
now verifies protected guest credentials, restricted service identity, cold boot,
fresh authenticated reconnect, restart and explicit removal. Production pairing
remains open. The per-VM Keychain source slice (private development record omitted)
now provides bounded add-if-absent custody and explicit stored-identity TLS/health
entry points, with injected failure and local transport guards. Native signed
Keychain custody and a real store-backed guest exchange remain unqualified.
[ADR 22](adr/0022-guest-agent-tls.md) records
transport; [ADR 23](adr/0023-linux-agent-installation.md) records the scoped installer.

`GuestAgent/Protocol/schema.json` generates Swift and C codecs plus shared vectors
through `generate.py`. A fixed 16-byte big-endian header carries magic MVOA, major,
minor, type, zero reserved bits and exact body length. Frames are bounded to 4 KiB.
Each typed body carries a 16-byte session, full-width sequence and request identity;
Hello includes VM identity and supported/required features. Minor revisions retain
known immutable message shapes; unknown types/major versions, extra/truncated
bytes and inconsistent lengths are rejected. Unsupported mandatory features fail;
unknown optional bits do not grant a feature. Only the health bit is implemented.

The host uses random session/request identifiers and validates exact replies before
health. Initial Hello/Reply uses sequence zero; health uses sequence one, the same
session and a new request ID. The evaluator closes on mismatch. Future persistent
heartbeat/accounting and larger integration messages require separate states
and tests; a two-message exchange is not complete replay or reconnect qualification.

Native macOS TLS verifies scoped CA trust, purpose, name, validity and an exact
enrolled peer leaf. The Linux server verifies client CA/purpose and exact DNS SAN.
The private relay forwards ciphertext only; a local endpoint is not authentication.
Actual TLS metadata must report TLS 1.3. Resumption/tickets and guest early data
are disabled. Application authentication precedes any health message. Private test
identities remain outside the project and are removed after actual terminal cleanup.

Bound identifiers, paths, frame lengths and outstanding requests. Session nonces,
monotonic sequences and authenticated request IDs resist replay/stale replies.
Set handshake/request timeouts, explicit cancellation, rate budgets and typed
errors; cap in-flight transfer memory. Logs contain stable events, never clipboard,
secrets, guest content or pairing data. Keychain denial disables pairing-dependent
integration with actionable recovery, not the unrelated VM boot path.

The experimental host store uses only a local Data Protection generic-password
item scoped by fixed development service and VM UUID. Each private bounded record
contains VM/enrollment IDs, host certificate/private key and exact CA/leaf/name
trust. It suppresses authentication UI and never resets, unlocks, rotates or falls
back after failure. A duplicate preserves the prior record. TLS still performs its
cryptographic validation; bytes read from storage do not establish guest health.
See [ADR34](adr/0034-per-vm-keychain-credentials.md) for signing and native gates.

Features: opt-in text/images clipboard with per-type limits; confirmed quarantined
file transfers with traversal/symlink defenses, cancel/resume; granted RO/RW folders;
resolution/DPI/topology requests with versioned desired/applied mode acknowledgments;
focus/layout/input release; bounded clock correction; heartbeat and clean lifecycle;
optional window/icon/launch/geometry messages behind seamless capability gates.

The future Windows privileged service handles narrowly authorized machine operations; the
per-user process handles desktop/window/clipboard access. No secure-desktop bypass.
Linux daemon/session separation follows equivalent policy. Signed explicit
install/uninstall, atomic upgrade and rollback require host+guest shared conformance
fixtures, malformed/fuzz input, reconnect and upgrade/downgrade tests. A connected
socket is not authenticated or healthy installation evidence.

### Windows byte-transport qualification

The original fixed transfer evaluator (private development record omitted)
uses a public read-first challenge/reply solely to qualify virtio-serial byte
transport. It cannot carry agent commands or authenticated health, and is not a
plaintext fallback for TLS. Cancellation retains an unfinished native request;
no reply or operation is replayed. Generated Hello/Health and mutual TLS remain
the required integration path after actual device qualification.

Windows credential hosting also has a separate [Schannel gate](adr/0038-windows-tls-credential-hosting.md).
The portable token contract (private development record omitted)
passes bounded input, final output and cancellation fixtures, but supplies no
cryptographic proof. The native in-process evaluator source (private development record omitted)
now attempts a TLS1.3 handshake, scoped certificate checks and two fixed encrypted
public records. Its static builds and descriptor fixtures perform no cryptography;
actual Windows execution remains unqualified. It exchanges no schema messages or
guest health. Import/acquisition and a static ARM64 build
cannot establish usable certificate signing. Windows record processing, enrolled
identities, signed service/session agents and the combined installer remain open.
