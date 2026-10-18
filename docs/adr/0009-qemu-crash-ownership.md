# ADR 9: retain QEMU ownership across app and worker loss

Status: experimental lease-spawn/Storage integration, actual-child
parent-descriptor-release proof and bounded intent/Core admission and history
binding passed. A recorded no-OS QEMU producer/opaque settlement trial passed;
one independent worker client-parent loss/reconnect trial also passed. Hard
worker loss has one paused pair and two controlled single-survivor custody/admission
trials. Recovered terminal/drain evidence and recovery/reconnect after
worker death remain pending.
Persistent disks, broader backend/UI adoption and Windows launch remain gated.

The current `VMLock` closes on exec. Process death releases its descriptors while
QEMU or swtpm may survive; a successful diskless run does not establish crash
ownership. This decision extends
[ADR 8](0008-qemu-process-lifecycle.md) without changing the macOS 14 product floor,
Windows workflow, native application or Liquid Glass requirements.

Progress: six ordinary local helper tests passed in session 77216 after the earlier
stalled 81661 run was preserved as inconclusive. They verify descriptor mapping,
parent-flag preservation, sampled unrelated-descriptor exclusion, either fake
child retaining the shared lock, failed-spawn cleanup and cancellation/explicit
reaping. Six backend pair tests (eight cases, session 58471) separately verify
partial launch, surviving-child retention and terminal/drain/callback settlement.
The aggregate session 47183 check passed 118 Swift tests with one explicit skip,
18 Python checks and 37 SBOM components. See the
lease-spawn evidence (private development record omitted) and
Swift runtime evidence (private development record omitted).
Subsequent integration and force-kill tests passed, and full session 26304 passed
124 Swift tests with one explicit entitlement skip, 18 Python checks, 37 components
and three historical benchmark structures. Two
actual-child lease trials (private development record omitted) observed the
same lock held after parent copies closed and with either exact child surviving;
both final terminal/drain outcomes and independent APFS lock reacquisition passed.
The earlier normal-QEMU-quit survivor assertion remains a preserved failure.
Closing parent descriptors is not a hard worker-crash test. Those trials did not
establish runtime intent settlement, worker IPC/reconnect, delayed-drain ownership
after worker loss or production crash safety.

The event monitor (private development record omitted) now retains Child
and pending actual-status waiters across cancelled callers and notification faults.
Nonisolated Sendable Dispatch bridges, bounded event-triggered reconciliation and
actor-only reaping/signaling passed focused tests and new native lifecycle
qualification; full session 4680 passed 132 Swift tests with one explicit skip,
18 Python checks, 37 components and three historical benchmark structures. A
three-trial-per-revision host-process comparison recorded lower parent CPU samples
with an unchanged harness/package, but establishes no confidence interval,
regression, guest, wakeup or energy result. Notification faults are internal
diagnostics to surface in future worker IPC, and unresolved waits can remain
pending. No worker-crash/reconnect or persistent-disk acceptance follows.

Storage intent (private development record omitted) and
Core integration (private development record omitted) now provide
bounded under-lock admission, a durable one-shot begin permit, matching saved
identity checks, permit/session history binding and redacted read-only intent
classification. The failed default-reader run is preserved; the explicit distinct
reader passed 17 new tests and synthetic CLI rejection/media-preservation checks.
Full check 2795 passed 159 Swift tests/one entitlement skip, 18 Python checks,
37 components and three historical benchmark structures. Producer ordering and
sealed terminal/drain/final-history receipts were not delivered at that revision.
Matching settled intent cannot authorize a new no-permit history writer.

Recorded runtime settlement (private development record omitted)
now qualifies the package receipt boundary and one fresh diskless native producer:
same intent/history session, both terminal/finished drains, settled intent and
honest forcedStopped final history, with independent post-exit writer availability.
Final focused 55216 passed 27 registrations; full 88222 passed 186 Swift tests/one
entitlement skip, 18 Python checks, 37 components and three historical structures.
Earlier sandbox and callback-snapshot failures remain preserved. Commit-gate tests
prove cancellation/failure retention and successful last-close release. This does
not establish app/worker loss, reconnect, clean guest shutdown or Windows adoption.
Subsequent review corrected late force-request outcome relabeling. Actual typed
observation determines successful outcomes and sticky runtime failure wins;
focused 58666 passed 17 tests and final full 95485 passed 187 Swift tests/one skip,
18 Python checks, 37 components and three historical structures. The earlier
native trial retains its tested source/CLI pins; no new native trial followed.
The final post-seal stop-callback guard preserves the decoded final history record/classification;
focused 46158 passed five owner tests and full 53300 passed 187 Swift tests/one skip,
18 Python checks, 37 components and three historical structures. Final controller
pins are recorded separately from the historical native trial.

Implement one original, unprivileged worker per runtime session. The worker owns
`VMLock`, `QemuMachineBackend`, `VMController`, ordered runtime history and both
bounded output drains. The app is a detachable observer/controller through a
private Unix socket. The worker must survive app or console loss; its own standard
streams must not depend on an app-held pipe. App disconnect, cancellation or
object destruction does not cancel worker operations or authorize child shutdown.
This slice needs no global service registration or privileged helper.

Before launching either child, the worker acquires the writer lease and durably
records bounded session intent. Current schema 1 has exactly VM identity, fresh
session UUID, schema version and unsettled/settled state; private IPC endpoint
binding requires separate bounded metadata or an explicitly versioned extension.
Every cooperating mutator must inspect that intent while
holding the writer lock: only the owning worker may write for its live session;
other or uncertain writers must reject an unsettled session. A missing IPC
endpoint, stale PID or available lock is insufficient to clear it. Only observed
terminal status for both launched children, EOF and finished state for both output
readers, and settled ordered history permit a durable settled record. Preserve
interrupted intent and evidence when those observations are lost. The intent rule
blocks unsafe retries; it does not prove that a kernel lease survived worker death.

Keep `runtime.json` advisory and the intent admission boundary in Storage, avoiding
a VMStorage-to-VMCore dependency. The implemented Core binding uses the same session
UUID and one permit-owned history writer. App/CLI writable admission and media
transactions check matching saved identity under the acquired lease; read-only
doctor can report unresolved intent even when the kernel lock is available.
New-directory creation remains exclusive. The recorded no-OS QEMU producer now
commits file/directory flush before child launch, retains the exact permit and
obtains sealed same-session terminal/drain and ordered-history receipts before
settlement. Next move this owner into the independent worker and qualify broader
backend/UI adoption and loss/reconnect. Freeze uncertain commits; disk UUIDs never
reconstruct continuation authority. No automatic intent clearing or orphan-PID
signaling is introduced.

IPC initially offers status, pause, resume and explicit force stop, with bounded
frames, unique IDs, deadlines, same-UID peer checks and private socket ancestry.
Reconnect binds the same VM/session and receives ordered observed state before
mutation. Reconcile timed-out commands through status. Client EOF or worker loss
does not authorize replacement launch, stored-PID signaling, orphan adoption or a
clean shutdown claim. Guest ACPI shutdown remains unverified.

Production additionally requires copies of the **same locked open-file
description** retained across exec in **both QEMU and swtpm**. The worker retains
its own copy through normal child, drain and history settlement. Do not reopen the
lock path as a substitute for duplication, unlink `writer.lock`, or call
`LOCK_UN`: explicit unlocking through a shared duplicate affects the shared lock.
[Apple's flock documentation](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/flock.2.html)
describes the shared lock references and advisory cooperation requirement.

Public `posix_spawn` file actions can inherit or duplicate the lease, with
`POSIX_SPAWN_CLOEXEC_DEFAULT` closing unrelated descriptors. Keep parent
`FD_CLOEXEC` unchanged; duplicate before closing temporaries, avoid descriptor
collisions and check returned error codes. Foundation `Process` exposes no public
arbitrary-descriptor mapping hook in the reviewed SDK. Its public `spawn.h` and
manual page document `adddup2` and `addinherit_np`; the latter clears child
close-on-exec. Verify the available public APIs on macOS 14.
[Apple's posix_spawn documentation](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/posix_spawn.2.html)
describes inheritance and file actions.

Pinned QEMU 11.1.0 `-add-fd fd=N,set=K,opaque=...` registers a duplicate in an
fdset; startup cleanup closes the original input. Nonempty fdsets retain their
descriptors until removal or exit, providing a candidate lease-retention path.
The exact named binary retained that lease in the parent-close/survivor trials.
Keep it outside guest devices and exclude `remove-fd` from IPC. This does not
guarantee other builds. [QEMU invocation](https://www.qemu.org/docs/master/system/invocation.html),
[QEMU 11.1 startup descriptor handling](https://github.com/qemu/qemu/blob/v11.1.0/system/vl.c),
[QEMU 11.1 fdset lifetime](https://github.com/qemu/qemu/blob/v11.1.0/monitor/fds.c).

Swtpm 0.10.2 has no documented generic lease-retention parameter; its state-store
lock is separate. The exact installed binary now has scoped unused-descriptor
retention evidence after parent close and QEMU SIGKILL; other builds, dependencies,
hosts, recovered survivor observations after hard loss and delayed drains still need
verification. Do not repurpose log, key or
socket descriptors.
[swtpm 0.10.2 interface and foreground lifecycle](https://github.com/stefanberger/swtpm/blob/v0.10.2/src/swtpm/swtpm.c).
Worker loss also loses wait/drain evidence. Even with surviving child-held leases,
record interrupted or unknown ownership; guest availability and automatic orphan
recovery are not established.

Acceptance, using fresh synthetic files and ordinary local children first, then
the exact pinned new no-OS QEMU/swtpm pair:

- App loss at each startup boundary and while running leaves the second writer
  busy; a new app reconnects to the same worker/session and reconciles state.
- Hard worker loss leaves an independent `LOCK_EX | LOCK_NB` attempt busy while
  both children, only QEMU, or only swtpm survive. Verify the same lock-file
  identity and inherited lease retention in the exact binaries.
- One child exiting cannot release the other's lease. Partial launch, cancellation
  and control failure cannot implicitly terminate a surviving child.
- Normal worker ownership remains through terminal children with inherited pipe
  writers, and releases only after both terminal statuses, EOF/finished drains and
  history settlement. An interrupted intent blocks every cooperating mutator even
  after the kernel lock eventually becomes available.
- Unrelated descriptors are not inherited; spawn failure closes temporary copies
  without unlocking the caller's lease. Explicit signaling and reaping are
  serialized so a reaped PID cannot be reused as a signal target.
- Preserve bounded source/binary hashes, argv, descriptor and lock-file identities,
  observed states, independent lock-probe results and terminal/drain outcomes.
  Run the public-API and filesystem lock tests on the minimum macOS 14 target.

No persistent or user disk is adopted until this evidence passes for both actual
children and the supported filesystem. Kernel lease survival, reconnect, guest
shutdown and Windows compatibility remain separate claims.

Settlement implementation now follows an opaque receipt boundary. BackendAPI
owns package-scoped actual-backend quiescence evidence, Storage owns history and
combined receipt types, and Core combines only its retained objects. Receipt
initializers are unavailable to public callers; disk UUIDs or caller booleans do
not substitute for observed completion. The recorded QEMU backend binds the session
before any launch, then seals future operations before minting terminal/drain
evidence. History binds the same permit, seals its ordered writer, and verifies
its exact successful final bytes. Storage compares and flushes that actual
same-anchor history file before committing settled intent. A retained recorded
owner delays external release until successful commit; ambiguous failures retain
explicit recovery custody and never retry, unlock or roll back automatically.

Physical quiescence can settle an honestly recorded failed or forced run. A typed
termination observation distinguishes process exit, explicit force and observed
guest stop; QEMU's current process exit does not prove guest shutdown. Evidence
must cover partial/no-launch/cancellation, pending output/history, mismatched or
reused source/session, post-commit ambiguity and permanently sealed operations.
The recorded QEMU native producer has one narrow passing trial; Apple has typed
termination observation but no settlement receipt. This boundary remains
experimental until its complete worker-loss/reconnect and broader adoption contract
passes; Windows and persistent-disk gates remain.

The verified worker slice (private development record omitted)
uses a distinct worker entry point in the existing CLI,
restricted to a newly prepared pinned diskless fixture. Before acquiring the lease
it creates its own session with checked public `setsid`, with standard input from
`/dev/null` and output in private regular files. A private Unix endpoint accepts
bounded versioned status, pause, resume and explicit force-stop frames from the
same UID. Every connection first reconciles the exact VM/session and observed
revision; stale mutation, repeated identifiers and concurrent operations reject.
Client disconnection or deadlines close only that transport. The worker retains
the actual operation, backend, output drains and recorded owner until confirmed
ownership settlement. No global service or automatic replacement worker is added.

One actual client-parent SIGKILL and same-session reconnect trial passed while
the native no-OS pair remained active, with an independent writer rejection on
the same file identity during the gap, observed pause/resume through IPC and
explicit final stop followed by terminal/drain/history/intent settlement.
Final full 89060 passed 204 Swift tests/one entitlement skip, 18 Python checks,
strict formatting, 37 components and three historical structures. Earlier compile/
format failures and the late-admission review correction remain recorded. No
orphan-worker exit status is claimed; final writer availability was probed only
after settlement. Ordinary local transport tests cover
malformed/version/identity frames, size and connection limits, duplicate IDs,
stale revision and a disconnected waiter while its operation completes. Hard
worker loss, surviving-child lease custody, minimum-host execution and persistent
Windows adoption require separate qualification and remain open beyond the narrow
paused pair-custody case below.
The [fixed worker schema](../runtime-worker-protocol.md) is separate from the
guest-agent protocol and establishes no GUI app-death or clean guest shutdown result.

The hard-loss evidence (private development record omitted) adds
one registered worker SIGKILL after original EFI completion and IPC pause. Both
exact children survived, the same pre-loss private QMP endpoint reported paused,
and the same writer identity remained busy. Public same-endpoint QMP quit later
made the kernel lease available while intent/history stayed unchanged unsettled/
paused pending. Separate actual Storage admission rejected both matching and nil
expected identity, preserving the bounded inventory. No terminal/drain/receipt
evidence was recovered and no intent settlement was written after loss.

The earlier trial failed before SIGKILL on a QMP mode guard and remains preserved;
confirmed live IPC cleanup succeeded. The repaired harness accepts only owner
0600/0700 QMP modes with unchanged UID/type/link/private-parent/endpoint/peer guards;
WorkerIPC still requires 0600. Final full 56309 passed 204 Swift tests/two explicit
skips and 24 Python checks, strict formatting, 37 components and three historical
structures; the enabled native admission filter passed separately. This proves
neither each individual child's post-loss lease nor lost-observation recovery,
settlement, running guest, Windows, minimum host, power loss or persistent adoption.

Controlled single-survivor trials (private development record omitted)
subsequently qualified TPM-only and paused-QEMU-only lease retention after exact
registered worker SIGKILL. A separate original fixed lab producer observes the
first child terminal/drained before READY, records failed-active history, and
retains all worker lease copies. Public captured-endpoint cleanup frees the kernel
lease; actual Storage still rejects unsettled intent without changing inventory.
No surviving-child terminal/drain evidence, receipt, settlement or adoption is
recovered. The TPM case is bound to its earlier producer/binary; the QEMU case is
bound to the monitor-handoff repair. The failed pre-loss QMP attempt and successful
preauthorized fallback remain preserved. These lab controls do not become
production partial-fault policy, IPC debug commands or orphan-PID authority.

Apple/Core stop ordering (private development record omitted) passed seven
pure production-driver registrations/11 cases and one real metadata history case.
Actual native completion/inactivity confirms force; native-error priority and
confirmed force survive late guest callbacks. An initiating native error after a
delegate ended the operation produces final failed history. No new native VZ,
Apple receipt, raw-reference/serial ownership or minimum-host proof follows.
Final full 49714 passed 212 Swift tests/two explicit skips and 28 Python checks,
strict formatting, 37 components and three historical benchmark structures.
Recovered observations, post-loss settlement/adoption, delayed drains, running
guest/Windows, GUI, minimum-host and filesystem/power-loss gates remain open.
