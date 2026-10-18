# Runtime worker protocol — experimental

This local host-control protocol follows [ADR 9](adr/0009-qemu-crash-ownership.md).
It is separate from the [guest-agent protocol](guest-agent-protocol.md). The first
worker entry point is restricted to a fresh pinned diskless fixture and retains
the actual RecordedRuntimeOwner. One client-parent loss/reconnect trial and bounded
transport/coordinator tests passed (private development record omitted).
This is a narrow CLI no-OS implementation, not a complete application recovery contract.
One paused hard-loss pair/admission trial (private development record omitted)
also passed. Windows, persistent-disk adoption, macOS 14 and recovery after worker
death remain gated.

## Endpoint and custody

The unprivileged worker creates its independent session with checked setsid before
acquiring the writer/permit. Its input is /dev/null and output uses private regular
files; app-held pipes do not own its lifetime. The private Unix endpoint requires
owned safe ancestry, no symlink ancestors, a private parent/socket and same-UID
peer verification. The shared transport fixes path and connection bounds; this
slice accepts at most eight clients and 32 requests per connection.

VM/session identifiers correlate a connection with the actual live owner. Reading
them from disk, finding a socket, observing a free kernel lock or finding a PID
does not authorize replacement launch, orphan adoption or signals. Same UID is a
local cooperating boundary, not proof against a hostile same-user process. Public
diagnostics and logs must omit identifiers, paths, process IDs and raw payloads.

## Fixed packets

Packets have a four-byte big-endian payload-length prefix, with a 128-byte payload
cap checked before allocation. Requests have exactly 56 payload bytes (60 framed);
responses exactly 64 (68 framed). The first four payload bytes are version 1,
tag request 1 or response 2, and two reserved zero bytes. UUIDs occupy 16 bytes;
UInt64 fields are big-endian, without JSON safe-integer restrictions; request IDs
must be nonzero. Boolean bytes are exactly 0 or 1. Reject bad size,
version/tag, nonzero reserved bytes, trailing bytes, unknown enums and noncanonical
booleans before dispatch. The codec's encoders return the complete frame; decoders
receive the already bounded payload without its length prefix.

| Request payload offset | Field | Type / purpose |
|---|---|---|
| 0–3 | header | Version/tag/reserved as above |
| 4–19 | vmID | Exact VM UUID |
| 20–35 | sessionID | Exact recorded session UUID |
| 36–43 | requestID | UInt64, increasing within this connection |
| 44–51 | observedRevision | UInt64, required current observation for mutation |
| 52 | command | WorkerCommand UInt8: status 0, pause 1, resume 2, forceStop 3, stop 4 |
| 53–55 | reserved | Three zero bytes |

| Response payload offset | Field | Type / purpose |
|---|---|---|
| 0–3 | header | Version/tag/reserved as above |
| 4–43 | vmID, sessionID, requestID | Same layout as request; exact correlation |
| 44–51 | revision | UInt64, worker's current observed revision |
| 52 | state | UInt8, fixed Core state index |
| 53 | ownership | UInt8, recorded ownership classification |
| 54 | backendActive | Bool; actual runtime custody remains active |
| 55 | operationPending | Bool; worker-owned operation is unresolved |
| 56 | error | ReplyCode UInt8 |
| 57–63 | reserved | Seven zero bytes |

Core state indices are fixed: stopped 0, starting 1, running 2, pausing 3,
paused 4, resuming 5, stopping 6, saving 7, suspended 8, restoring 9 and failed 10.
Ownership indices are unsettled 0, settling 1, settled 2 and recoveryRequired 3.
Reply codes are none 0, busy 1, stale 2, identity 3, operationFailed 4 and recovery 5.
These mappings are fixed by the shared packet API, not inferred from declaration
order. No command launches another runtime, edits media, changes stored identity
or clears intent. The new experimental stop opcode requests normal shutdown through
the retained backend; its reply does not establish guest acceptance or completion.
Older immutable version-1 workers reject opcode4 as unknown. The protocol has no
capability negotiation for this addition; use it only with a known new worker.
It is not exposed in the existing private display App controls.

## Status before mutation

Each connection starts unreconciled. Its first accepted request must be status
for the exact VM/session; every reconnect repeats that step. The client validates
response identities and records revision before a mutation. A structurally valid,
matching status response establishes that revision even when it reports a controlled
runtime failure, preserving explicit force recovery for still-active children.
Request IDs strictly increase within a connection; repeated or decreasing IDs reject, with no replay
cache. Exhausted request IDs require closing the connection rather than wrapping.
Revision exhaustion refuses new mutations; reconnect does not reset or renumber
the live session's observed revision.

The transport checks per-connection status reconciliation and increasing request
IDs. Each request consumes status freshness; only a status response restores it,
so every later mutation needs another status request. The Core coordinator checks
the actual owner's exact identity, current observedRevision, available ownership
and absence of another pending mutation. It reserves the next revision and pending
operation synchronously before any await. Another connection
cannot admit an operation using the old revision while that operation is pending.
Observed changes/completion advance revision; they never reuse an older value.
Busy/stale replies require fresh status before a new explicit mutation.

Pause, resume, normal stop and explicit forceStop act only on the retained live owner. A reply
reports current observed state and controlled error classification; command
acknowledgement is not terminal, drain or durable settlement proof. The existing
sealed backend/history receipts and Storage commit determine ownership settlement.
Failed or uncertain settlement retains recovery custody, even if bytes may already
have changed after rename.

After normal-stop request acknowledgement, stopping state and backend ownership
remain pending until actual guest-stop observation and durable receipt settlement.
An opaque exit remains failed even after a successful request. The QEMU event and
owned-process evidence needed for that observation are specified in
[ADR 25](adr/0025-qemu-guest-shutdown-observation.md); actual Windows ACPI response
is not yet qualified by the source/contract work.

## Lost connections and deadlines

Client EOF, timeout or cancellation closes only its transport. Once admitted, the
worker retains and runs the actual operation independently; no disconnect handler
signals children, releases the writer, settles intent or cancels that operation.
Client request timeout must be positive, defaults to three seconds and is capped
at 30 seconds. Server idle frame reads and writes have three-second deadlines.
Losing a reply leaves the operation's result unknown to that client.

Reconnect, request status and inspect current revision/pending/ownership state.
An old mutation is not resent. A new explicit action uses a fresh increasing ID
and the newly observed revision. This is reconciliation, not replay protection
across connections, exactly-once delivery or an idempotency guarantee. Missing
endpoint or worker death cannot turn uncertainty into replacement authority.

## Qualification and remaining gates

Ordinary local transport tests cover malformed packets, identity/version,
frame/connection/request bounds, nonincreasing IDs, stale revisions, status-first,
concurrent admission and a disconnected waiter whose owned operation finishes.
The actual native trial retained the no-OS pair and same writer-file exclusion
during client-parent SIGKILL, reconnected to the same session, observed IPC pause/resume,
and finished explicit stop plus terminal/drain/history/intent settlement. The
late-frame admission test rejects new requests after server finish starts while
preserving previously accepted callbacks.

The client-loss trial does not prove GUI app loss. A later paused hard-loss trial
observed both children live and the same busy lease, then actual Storage rejected
unsettled intent after public QMP cleanup freed that lease. It recovered no child
terminal/drain evidence or settlement receipt. Later
single-survivor trials (private development record omitted)
observed each exact survivor's retained lease in a separate fixed lab producer,
whose first-exit/fallback controls are not protocol commands. Lost/delayed
observations, recovered terminal/drain receipts, reconnect/adoption after loss,
filesystem/power-loss recovery, broader UI/backend
adoption, Windows and minimum-host acceptance require separate evidence. The
recorded settlement evidence (private development record omitted)
qualifies the underlying owner; the client-loss evidence (private development record omitted)
records the separate worker's exact source/artifact pins and scope.
