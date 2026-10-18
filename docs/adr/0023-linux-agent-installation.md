# ADR 23: persistent restricted Linux guest tools

Status: experimental Alpine/OpenRC installation evaluation.

Advance the demonstrated guest transport into an explicit install, supervised
nonlogin service, restart/reconnect and uninstall workflow. Preserve every source
VM. Prepare only a new copied installed guest; its old test shutdown hook may be
renamed to a retained disabled backup from a normal live environment. Never use
an authentication-bypassing bootstrap or mutate the original VM to make tests pass.

Separate generic signed payload from per-VM enrollment. An independently approved
Ed25519 issuer authenticates a canonical SHA256SUMS file for agent/initd/setup.sh;
the host verifies signature and each byte before handing that manifest pin to the
explicit guest setup tool. The guest verifies the exact approved manifest and its
staged payload. A hash alone is not signature authority, and a key supplied only
by the package cannot approve itself. Development issuer keys are temporary and
kept outside the project; release publisher pin/signing remains a separate gate.
Per-VM credentials never enter the generic signed package or release image.

The service uses a dedicated locked nonlogin account, private guest credential
directory and no capabilities. It accepts only the implemented TLS health protocol,
with bounded sequential clients, deadlines and failure/log budgets. Installation
is explicit, conflicts preserve existing state, and partial operations keep their
staging evidence. Uninstall normally stops/disables the service and removes only
identified owned payload. Credential removal is an explicit option; unrelated
accounts/files and retained backups are preserved. Production signing/enrollment,
key rotation, upgrades/rollback and other Linux init systems remain open.

Acceptance: verified signed payload and tamper rejection; actual disk install;
nonroot UID/GID and empty effective capabilities; service health after setup-disc
detach and cold boot; host reconnect and service restart; normal VM shutdown;
uninstall prevents later connection and preserves unrelated files; source VM hashes
unchanged; no private keys in project or logs. Windows service/session and signed
one-disc setup remain part of the full objective and require their own route.

The installed trial's one per-VM support carrier explicitly mounts ISO9660 with
`ro,norock`, selecting its verified Joliet namespace. This matches the earlier
proved support carrier path. Host preflight decodes public Joliet payload records
and compares the exact approved manifest/payload bytes before VM launch. There
is no filename-search fallback and enrollment contents are never catalogued.
Metadata ownership of readonly media is separate from root-owned installation
state and private service-owned credentials.

Executable parents must be searchable by the dedicated service identity. The
installer creates missing standard parents as 0755 and rejects existing root-owned
parents without the other-execute bit before staging or account creation. It does
not normalize existing permissions; 0711 is acceptable and 0700 is preserved with
a specific error. Private credential and ownership-state directories remain 0700.
The native test prepares its fixed hook in the installed guest's existing sbin
directory and leaves libexec creation to the installer.

## Next transaction slice: owned reinstall

Keep a bounded root-private account reservation outside removable installation
state, tied to the VM UUID and exact locked nonlogin service-account/group
contract. Fresh provisioning creates the reservation only after validating that
contract. Reinstall can reuse that proven identity; an unreserved same-name account,
drift or a prior orphan from the older uninstaller remains a conflict. Preserve
existing account/group policy rather than silently changing or removing it.

Default uninstall that retains credentials preserves their exact approved hashes
in the private reservation. Reuse requires an explicit retained-enrollment mode
and unchanged bytes/modes/ownership for the same VM. After explicit credential
removal, require fresh separate root-owned enrollment for the same VM; never
silently rotate credentials or adopt files merely because a name matches.

This first slice does not add upgrade/RPC APIs. Later A-to-B-to-A changes must stage
beside each destination, stop normally before replacement, retain one known previous
generation and journal each rename for explicit validated recovery. Multiple
renames are recoverable transactions, not one atomic operation. No power-loss
durability claim follows from shell rename/readback without verified parent/file
flushes. Acceptance remains tamper/interruption/stop-failure preservation and actual
health through uninstall/reinstall plus cold boot, with source VM bytes unchanged.

Explicit fresh re-enrollment now passes on a third installed boot (private development record omitted): prior removal is verified, the same private account reservation and UID/GID are reused, and a changed private TLS identity completes native health before final removal and normal shutdown. This does not establish live rotation or rejection of the old peer; those require separate evidence.

## Compatible-manager generation transactions

The next source slice adds explicit `upgrade`, `rollback` and journaled `recover
--resume` for a fresh v2 installation. It preserves the VM, locked account and
enrollment. A and B must contain the same setup-manager and OpenRC script bytes;
manager self-updates and v1 migration are outside this slice. V1 or mixed-manager
state is rejected before service or file mutation. V2 also marks the permanent
account reservation, including after credential removal; removing installation
state must not let an old v1 reinstall bypass current kernel exclusion. The
retained v1 test fixture must independently reject installed, retained and removed
v2 states before service, account or file mutation.

All current mutating actions acquire a process-held kernel lock on one permanent
root-private inode. The inode is never removed or replaced. A stale journal is
recovery evidence, not authority to reclaim a live lock. `flock` and the required
Linux process inspection must be present before mutation; setup never downloads
or installs missing tools. Normal service-stop acknowledgement is insufficient:
replacement requires fresh proof that both the service and its supervisor are
quiescent, including no remaining dedicated-account processes.

Native testing exposed a procfs detail absent from the first fixtures: a kernel
thread or exited process can retain an `exe` symlink whose target is unavailable.
The corrected scanner first validates bounded kernel status and all four UIDs,
then accepts a proven kernel thread with root identities and empty arguments, or
a proven exited process with empty arguments. A failed executable lookup on a
previously live process requires a fresh status/UID/argument read; live, malformed,
inaccessible and service-account processes still refuse replacement. Saved PIDs
never authorize skipping or controlling a process. See the public Linux
[executable-link implementation](https://raw.githubusercontent.com/gregkh/linux/v6.18.55/fs/proc/base.c),
[kernel-thread executable handling](https://raw.githubusercontent.com/gregkh/linux/v6.18.55/kernel/fork.c)
and [process argument semantics](https://man7.org/linux/man-pages/man5/proc_pid_cmdline.5.html).

Each program/state stage lives beside its destination. A bounded write-ahead
journal identifies the VM, account, retained enrollment and exact current/target
generation hashes. Recovery accepts only the exact pre- or post-rename namespace
for its recorded phase; missing, duplicated, altered or ambiguous evidence is
preserved and rejected. No automatic restart, rollback or evidence pruning occurs
after failure. One prior generation is retained; explicit rollback retains the
failed replacement, and occupied history blocks another upgrade.

Acceptance: actual kernel-lock contention across every action; failures before
and after every rename/journal publication; false stop acknowledgement, supervisor
survival, start and post-start commit failure; wrong VM/generation/manager,
tampered or ambiguous recovery; unchanged credentials, modes, inodes, account rows
and unrelated files through A–B–A. Portable fixtures do not prove native root
ownership or power-loss durability. Native qualification additionally requires
distinct agent binaries and authenticated versions across A–B–A, a disc-detached
cold boot, normal VM shutdown and preserved source VM bytes. Production publisher
trust, GUI delivery and additional init systems remain separate gates.

Generation preparation (private development record omitted)
now provides two reproducible, distinct ARM64 test agents and same-issuer signed
test payload support. It establishes no guest upgrade or recovery result.

The fresh recorded native generation trial (private development record omitted)
passes with the corrected AppleVz CLI: real recorded-session permits, matching
VM/session history and settled intent, actual normal SDK guest-stop callbacks,
parent reap/full drains and an independent kernel writer-lease check before disc
detach or reboot. It authenticates A/B/B/A/A across three installed boots while
preserving account and credential identity. Earlier immutable legacy trials and
their failed runs remain historical evidence and are never relabelled.

This proves compatible-manager Alpine/OpenRC generation upgrade and rollback on
the named host. Real interrupted-transaction recovery, evidence retirement, manager
self-updates/v1 migration, production publisher trust, product GUI setup, desktop
session integrations, Windows and older-host/release qualification remain open.

Next recovery slice: implement explicit retained-evidence retirement after a
completed rollback, before enabling another compatible upgrade or uninstall.
The decision and acceptance criteria are in [ADR27](0027-linux-generation-retirement.md).
The executing/payload manager bound will be raised explicitly to 128 KiB where
this new manager is admitted, keeping credentials and other metadata bounds intact.
Previously signed 43d installations remain bound to their own manager; no migration
or adoption of those installations is implied.
