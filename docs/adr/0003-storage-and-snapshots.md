# ADR 3: existing disk formats, durable metadata, gated snapshots

Status: accepted conservative storage; snapshots planned.

Start with sparse raw and explicit allocated/virtual sizes. Use exclusive lifetime
locks, atomic metadata replacement and fsync. Reject truncating existing files,
novel block formats, copying live writable disks, or auto-repair after a crash.

Snapshot/save APIs are not sufficient: coordinate memory/device/disk state and
guest quiescing separately. Mark crash-consistent versus guest-quiesced results.
Gate all snapshot operations behind disk-full, interruption, power-loss and
corruption campaigns proving preserved last good state and restored guest data.
Clone must avoid shared writable blocks and regenerate appropriate identity/pairing
without silently destroying source TPM state. Templates follow the same rules.

Acceptance: writer exclusion across processes, atomic replacement fault tests,
bounded read-only diagnostics, free-space preflight and safe failed creation.

Writable preflight uses a no-follow directory descriptor and a relative, regular,
single-link private writer lock. Nonblocking opens reject FIFO/special-file inputs
before reads or flushes. GUI/CLI launch and native validation reject hard-linked
writable disks/EFI stores, wrong ownership and group/world write bits; read-only
inspection can still explain those files. Reject unsafe permissions without
changing them automatically. Checks use POSIX mode bits; ACL review, same-user
path substitution races between preflight and framework attachment, ancestor
permissions and non-cooperating tools remain unresolved. Do not infer complete
local-attacker protection or crash recovery from these gates.

Runtime history is advisory project metadata, separate from configuration and disk
integrity. Commit a launch intent under the lifetime writer lock before calling the
backend; order subsequent state observations and retain ownership until final
persistence settles. Archive the previous valid record under its controlled UUID
without replacing existing bytes. Corrupt/unsafe history is preserved and blocks a
new recorded launch; there is no automatic repair. A free lock plus an unfinished
record means interrupted or unreconciled, never clean shutdown. Distinguish guest
stop observation, explicit force stop and failure. Neither history nor fsync calls
establish guest filesystem or host-power-loss consistency. These gates remain
experimental until actual process-failure and persistence tests pass.

Installation-media changes are stopped-only metadata transactions, never disk
hot-unplug or installation detection. Hold cooperating ownership, require private
supported registration, reject ambiguous/unknown fields, and retain an exclusive
exact-byte backup before replacement. Preserve identity, disk and EFI store.
Cancellation before commit leaves the original registration; post-rename failure
is uncertain and must retain both versions without automatic rollback. Recheck
registration before commit to detect intervening non-cooperating edits; same-user
path races after that check remain a separate gate.
