# ADR 26: recorded ownership for the Apple backend

Status: backend and CLI source tests and fresh recorded Linux cold boots pass narrowly; desktop integration pending.

Use the documented [VZVirtualMachine API](https://developer.apple.com/documentation/virtualization/vzvirtualmachine).
The selected SDK's public header specifies the VM's serial queue for operations,
completion handlers and delegate calls. The default queue is main; the new queue
property itself requires macOS 26 and cannot be used unguarded in a macOS 14 target.
The [stop completion API](https://developer.apple.com/documentation/virtualization/vzvirtualmachine/stop%28completionhandler%3A%29)
is destructive and remains separate from the
[guest-stop delegate](https://developer.apple.com/documentation/virtualization/vzvirtualmachinedelegate/guestdidstop%28_%3A%29).

The Apple backend now implements `BackendSettlementSource`. CLI `run` and the
agent transport trial open `RecordedRuntimeOwner` with the actual writer lock
before exposing the native handle. The desktop still uses legacy advisory history.
Earlier immutable trial binaries retain that legacy profile and their evidence.

Implement the backend settlement boundary first, with injected native-operation
and callback ordering tests. Bind one actual backend instance to one recorded
session before launch. Track all pending start, stop, force-stop, pause and resume
operations and a separate outstanding terminal callback in the active/settlement predicate. A recorded instance admits one
start attempt, preventing queued callbacks from an earlier run being accepted as
evidence for a new session. Preserve the unbound legacy behavior where needed.

Accept delegate callbacks only from the exact owned `VZVirtualMachine`, and never
after permanent sealing. Latch terminal observations while a native operation is
pending; publish stop/failure only after all relevant completions and actual
native inactivity. Native errors remain sticky and cannot become guest shutdown.
Forced termination remains distinct. Missing callbacks or native error state do
not establish `guestStopObserved`.

Freeze requires the exact bound session, native inactivity and no pending native
operation or outstanding terminal callback. Seal the instance permanently before issuing its typed receipt; keep
the source retained through durable history/intent settlement. Cancellation of a
caller does not authorize force stop, drop a pending native completion or release
writer ownership.

The CLI joins its shutdown-request task and agent relay before committing history
and intent. A metadata failure retains the actual backend, lock and owner in a
dormant recovery lifetime. Next integrate the desktop's actual `VMLock` with the
same owner and qualify fresh runtime sessions.
Preserve registered VM identity and existing disks. Do not promote source tests
to a native/GUI claim, alter live immutable executables, adopt saved PIDs or rewrite
older legacy history as a fabricated recorded receipt.

Acceptance: wrong/repeated binding, legacy-then-recorded admission, one-shot start,
pending native callbacks, cancellation, late/foreign callbacks, force/error
precedence, missing terminal observation, wrong-session freeze and repeated/late
operations after seal; receipt-source identity and blocked durable commits. Then
qualify a fresh real Linux runtime, normal shutdown, retained failure, exact
session intent settlement, independent kernel lease, and repeated GUI lifecycle
with new backend instances. Older-host and production release gates remain open.

Focused qualification: 33 Apple tests in two suites and five recorded-owner tests
pass in `.lab/apple-recorded-cli-058f7880abc640a59f353e29111c526e/`.
The preceding run's stale cancellation expectations and failure log are preserved.
Delayed own callback, foreign callback, successful start with inactive native
state, cancellation, control failure followed by actual guest callback and
inactive force no-op are covered. Native state alone never supplies stop evidence;
Core's missing-completion guard is unchanged.


The fresh compatible-agent A–B–A trial (private development record omitted)
now qualifies four actual recorded runtime sessions, including preparation. Each
returns guestStopped history and matching settled intent after the own SDK callback,
full process output cleanup and actual writer release. Three installed boots include
disc-detached cold B and cold A. This is real CLI/native evidence; desktop routing,
metadata-failure recovery, older hosts and broader production reliability remain.

The ordinary Liquid Glass desktop now prepares the actual recorded owner before
publishing the rendering handle. One helper retains the writer, backend and owner
through its exact controller's quiescent notification and durable settlement.
Preparation or commit failure preserves custody and blocks close/quit with an
inspect-and-preserve message. Successful commit releases input and the host cursor,
then clears the surface and ownership references. Deferred menu commands capture
and validate their original runtime before execution or error presentation.

Four new helper tests use real private files, intent/history commits and the actual
kernel writer lock, with injected backend events and a gated final commit. The
coordinated 59 registrations pass; after the deferred-command correction all 21
App registrations pass again on unchanged inputs. This proves source orchestration
and failure handling. A new private app build is prepared for review, without
replacing or launching any live app. Native graphical lifecycle, close/quit,
fullscreen/focus and macOS 14 acceptance remain unqualified for this revision.
