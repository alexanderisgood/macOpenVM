# 33. CLI controls for an existing registered Windows worker

Status: experimental implementation; local IPC, actual read-only CLI and native
no-OS pause/resume/refusal/forced-settlement passed. Windows lifecycle remains open.

Windows library Start retains an actual worker, but its lifecycle commands are
currently available through the app and evaluation helpers. The product CLI needs
equivalent controls without rebuilding runtime ownership from stored process IDs.

Add status, pause, resume, stop and force-stop commands for the existing registered
Windows worker. Require the VM directory, its explicit runtime folder and the
expected current session. Force Stop additionally requires explicit
`--confirm-data-loss yes`; reject missing or irrelevant confirmation before I/O.
Other backend profiles remain unsupported by this client until they expose their
own verified ordinary worker route.

Admission checks bounded private metadata, the exact registered route, the current
unsettled intent and a held writer. The client connects through the existing
peer-checked protocol, observes status, rechecks the selected records and sends one
command on the same connection with the observed revision. The actual server
retains its native owner and decides whether to admit the command. The client
creates no permit, takes no writer, adopts no process, sends no signal and never
retries a mutation automatically. Closing it affects only its connection.

A reply is observed status or an acknowledgement. It is not proof of completed
shutdown, reaping, full drains or disk integrity. Normal Stop requires a running
guest; the client does not silently resume a paused guest. Recovery ownership or
an inactive backend cannot be promoted to active control by stored metadata.

Acceptance: strict options and force confirmation; malformed, stale and indirect
route refusal; private real local IPC tests for fresh status/revision and preserved
files; current CLI build; read-only status against the actual existing Windows
worker. Native lifecycle mutation requires its own authorized scenario and
terminal evidence. The current test VM's Force Stop approval remains pending.

The implemented client passed six focused registrations, actual CLI option
refusals and read-only status on the current live Windows worker with unchanged
metadata. Evidence and limits (private development record omitted).


The next native contract trial uses a genuinely new, disconnected registration
with an empty sparse disk. An original README-only data ISO is used for file-only
creation and detached before boot; there is no OS, account, guest input or network.
Root will use the normal CLI to observe pause/resume states, reject normal stop
while paused and reject Force Stop without its explicit confirmation, then request
forced cleanup of this disposable no-OS fixture. Actual owned child termination,
drains, flush, Core forced outcome, settled intent and independent writer are
required afterward. This trial cannot qualify normal Windows shutdown or desktop
use, and does not authorize recovery of the separate installed test VM.

The no-OS native contract trial completed as scoped above with actual owned worker/child exits, drains, durable forced outcome and released writer. It qualifies this isolated lifecycle contract, not normal Windows shutdown or desktop use.
