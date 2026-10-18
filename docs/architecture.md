# Architecture

One original SwiftUI/AppKit application and one `macopenvm` CLI share domain
configuration, validation, creation and storage. Core depends on BackendAPI and
VMStorage, never a concrete framework type. VMCreationPlatform injects host checks
and platform identity creation; AppleCreationPlatform is its working Linux adapter.
AppleVz translates plain configuration into documented VZ devices. Qemu currently
provides an inspectable argv plan and an experimental process/QMP runtime.
The first real Swift-owned EFI lifecycle (private development record omitted)
uses only a new diskless fixture; Windows and persistent-disk adoption remain gated.
No competitor app or untracked app resources are dependencies.

Desired configuration is versioned separately from runtime state. State changes
carry operation IDs: completions from old operations cannot advance a new run.
Validate → acquire lifetime exclusive file lock → build backend → persist durable
starting history → start → observe actual stop/failure → publish truthful state
→ settle ordered history → release lock. Runtime history distinguishes a recorded
guest stop, observed forced termination and failure from an unfinished prior run. It is
advisory; a free lock never establishes clean shutdown or guest disk consistency.
A stop request is not a stopped VM. Failed stopping retains active ownership.

Storage uses existing raw disk files, atomic same-directory metadata replacement,
flushes and owner-only permissions. No proprietary or novel disk format. Locks
must cover every disk writer, including future CLI/GUI helpers. Recovery diagnoses
stale runtime state, does not delete files or auto-repair guest disks. Core owns an
ordered persistence chain for synchronous native callbacks and exposes a drain
before final release. Failed starting-history persistence prevents backend start;
later persistence errors preserve active ownership and are reported. Each prior
valid record is archived exclusively by its run UUID. Unsafe/malformed history
is preserved and blocks a new recorded launch.
The experimental recorded QEMU producer commits unsettled intent and retains its
permit before child launch. Existing GUI/Apple workflows have no settlement
receipt wiring; broader adoption remains pending.

New VM creation checks host capability/native limits and regular, nonempty selected
media before touching the destination. The directory must not already exist.
Creation flushes its parent entry, sparse disk and new identity files, then commits
configuration.json atomically as the registration marker. Failure/cancellation
preserves the incomplete new directory; no automated rollback deletes its files.
Power-loss recovery remains a release gate, not a claim established by fsync calls.

Framework operations are isolated to the main actor/main queue per public SDK
contract. Disk preparation/IO use an independent storage actor. Production adapters
inject storage, backend, clock and process boundaries. Async calls check cancellation;
cancelled start must reconcile any resulting VM before dropping ownership.
QEMU's two child processes and output workers form one lifetime. Control failures
retain active ownership; QMP acknowledgements do not establish child exit. Current
caller-only locks do not protect surviving children from an owner crash. Experimental
worker/child-held leases now have controlled client-loss and one paused hard-loss
pair-custody trial plus controlled single-survivor cases; recovered observations still require
qualification before persistent QEMU disks are exposed.

App display uses VZVirtualMachineView where viable, discovered backing-pixel
dimensions, native fullscreen and explicit input release. No UI action exists for
a backend capability that has no implementation. The experimental guest protocol
now has generated Swift/C messages and native TLS 1.3 health over a Linux virtio
socket. The named native trial (private development record omitted) verifies
an unknown-host rejection and valid exchange; production pairing, installed
service/session agents and full integration remain separate requirements.

Presentation follows [ADR 7](adr/0007-liquid-glass-interface.md): native Liquid
Glass controls and a small passive status layer on macOS 26+, semantic content
cards for readable information/forms, and native availability/accessibility
fallbacks. The host presentation does not style or overlay guest pixels, change
runtime ownership, replace native window chrome or add unsupported settings.

The [saved VM library](adr/0018-saved-vm-library.md) stores recent navigation
references in app-owned preferences. These references carry an expected UUID but
do not authorize runtime operations. Opening rereads bounded local configuration;
Start checks the selected UUID again before acquiring the existing matching writer
lock. The library sheet leaves the guest surface mounted, releases its input and
defers a selected entry until dismissal. A busy owner cannot be replaced. Windows
metadata selection shares editing logic while its existing launch gate remains.

Networking/Sharing boundaries document future integration work; empty modules are
not advertised as implementation. No secrets in configuration; future credentials
live in Keychain. Guest transport evaluation injects transient memory-only test
identities, independently of VM boot. Diagnostics require a separate redaction
boundary before export.

The experimental runtime-intent boundary (private development record omitted)
lives in Storage, separately from Core's advisory runtime history. VMLock reads
bounded intent under the acquired lease; unsettled or unsafe intent rejects a
cooperating writer even when the kernel lock is available. Beginning a session
uses the retained directory anchor, file and directory flush, readback and identity
rechecks before publishing a non-reconstructible permit tied to that actual lock.
The one-shot reservation is shared across storage actors and is not reset on
failure. A disk UUID never grants continuation authority.

Core intent integration (private development record omitted) now rereads
saved VM identity under the admitted lock before writable construction/media
transaction, binds one ordered history writer to the retained permit/session, and
classifies intent in redacted read-only diagnostics. No-permit history accepts only
absent intent; even matching settled metadata requires a new producer permit before
a subsequent start. Validation/persistence failures freeze history writes. Legacy
no-intent workflows remain available.

Recorded ownership settlement (private development record omitted)
now retains the actual QEMU backend/controller/history/permit through an owned
transaction, seals operations and committed history, and uses package-only
same-source/session receipts. Storage verifies and flushes same-anchor final
history before settled intent. Only successful commit releases the retained owner;
failure keeps explicit recovery custody and the failed result without retry.
One fresh diskless native trial and synthetic commit-gate/last-close tests qualify
this slice. General backend/UI adoption and hard worker-loss recovery remain required
work; path-based I/O does not close hostile same-user races.
Successful final outcomes follow actual typed termination observation, with sticky
runtime failures taking priority; a late force request cannot relabel earlier exit.

The independent worker slice (private development record omitted)
retains that owner in a separate checked session with independent private stdio.
RuntimeIPC transports fixed bounded frames; Core admits actual-owner mutations by
fresh observed revision and reserves pending state before await. One native client-
parent SIGKILL trial retained the same session and writer identity, reconnected,
observed pause/resume, and completed explicit final settlement. Transport cancellation
does not own runtime lifetime. This is no GUI app-death, hard worker-loss, minimum-host
or persistent Windows adoption proof. The [protocol](runtime-worker-protocol.md)
has no PID authority or automatic replay/replacement worker.

Paused hard worker loss (private development record omitted) now has
one physical pair-custody case: registered worker SIGKILL, both exact children live,
same paused QMP endpoint and same busy writer identity. Public QMP quit freed the
kernel lease without recovering child terminal/drain evidence; preserved intent/
history stayed unsettled/paused pending. A separate actual Storage test rejected
matching and nil-identity admission with a bounded unchanged inventory. This
demonstrates a conservative retry barrier, not post-loss ownership settlement,
orphan adoption, running OS, Windows or power-loss recovery.

Single-survivor hard-loss trials (private development record omitted)
now qualify each exact child's lease separately in an original lab-only producer:
the first child is terminal/drained before READY, while the sole survivor remains
live and holds the same writer after worker SIGKILL. Captured public-control cleanup
later frees the kernel lease; actual Storage still rejects unchanged unsettled
intent/failed-active history. This does not establish production partial-fault
policy or recover the survivor's terminal/drain/receipt evidence.

Apple native stop ordering (private development record omitted) uses the same
production MainActor driver with injected native closures. Confirmed native force
and error observations cannot be downgraded by late guest callbacks; Core records
final failure when a delegate ended an operation before its native call throws.
These are pure/contract tests with actual metadata, not new native VZ execution.
The public native-machine reference and caller-owned serial I/O remain receipt/
adoption constraints; no Apple quiescence receipt was added.
