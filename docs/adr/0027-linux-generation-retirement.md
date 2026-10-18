# ADR 27: explicit retirement of retained Linux generation evidence

Status: implementation planned; current 43d native upgrade/rollback evidence is preserved.

A completed rollback leaves current A, failed B, and its complete transaction
cohort. These slots deliberately block another upgrade and ordinary uninstall.
Silently deleting them would discard recovery evidence. The next operation must
free the active slots by archiving their exact owned contents, with explicit pins
and interruption recovery. Full update/recovery remains the objective; retirement
of a previous generation after an upgrade and manager migration are additional
required stages.

The first operation is `retire-failed --vm-id UUID --expect-generation A
--generation-sha256 B --retirement-id UUID`, with `--resume` for an interrupted
operation. It admits only an exact completed rollback, its matching published
upgrade cohort (canonical `start` or `complete` phase), compatible manager/service, reservation and private credentials,
current A with `previous=-`, and the exact failed B program/state. Staged, foreign,
malformed or ambiguous layouts refuse without repair or deletion.

Hold the permanent kernel exclusion inode across the operation. Normally stop the
service and prove current supervisor/agent/process quiescence from fresh process
state before namespace changes. Archive program evidence beside its own parent
and state/journals beside theirs, proving source/destination filesystem identity
before every rename; never accept a copy/delete fallback. Private archives use a
canonical caller-selected UUID and exact root-owned namespaces. Preserve all
current program/state/account/credential bytes and the kernel-lock inode.

Use a separate bounded canonical retirement journal and exact pre/post layouts.
Stage the exact canonical prepared record in the fixed adjacent retirement.next
directory before any initial flush; flush and rename that directory into the active
retirement namespace. Exact prepared staging can be explicitly resumed; partial
or empty staged bytes are preserved and refused. Flush prepared intent before
moving evidence, journal and flush each transition,
then retain the complete retirement receipt with its archived cohort. Publish a
separate exact completion record only after the final journal-directory move and
parent flushes: an archived journal alone must not imply committed completion if
a following flush failed. A fixed confirmation-unconfirmed record retains observed
publication/flush failure and blocks other mutators; exact resume revalidates and
reflushes the completed layout. This covers observed process errors, not proof of
SIGKILL or power-loss behavior in the final publication window. Explicit resume
handles an unfinished archived receipt.
Every other
mutator refuses unfinished retirement. Explicit resume accepts only the recorded
VM/current/failed/retirement identities and validated layout. Repeated completion
must not move or relabel unrelated evidence. Bound archive counts; refuse a full
namespace rather than prune it. Service restart stays explicit and is not implied
by archive completion or a saved PID.

The existing manager is 65,267 bytes. A coherent retirement implementation cannot
fit its remaining 269 bytes without sacrificing clarity. Raise the manager-only
admission/copy/self bound to 131,072 bytes, and explicitly update new carrier and
native runner admissions when those are prepared. Credential limits remain
65,536 bytes, manifests 512 bytes, ordinary generation journals 2,048 bytes, and
new retirement journals at most 2,048 bytes. Never silently expand a general parser
or adopt the previously signed manager. Publish fresh same-manager payloads only
after source/tests freeze; old generic packages and qualified private VMs remain
untouched. The archived v1 fixture and its rules remain historical.

Acceptance: exact A→B→A→retire B→C upgrade with preserved current identities;
wrong pins/VM/UUID; foreign/symbolic/hardlinked/permission/namespace tampering;
actual kernel-lock contention for every mutator; false normal-stop acknowledgement
and live service/supervisor/process refusal; every move/journal/flush interruption
followed by repeated explicit resume; preserved exact archived journals and source
inodes; canonical/partial journal refusal or documented exact recovery; archive
count exhaustion. Run portable source fixtures with real host filesystem and lock
behavior, then a fresh native guest campaign. Neither campaign alone establishes
power-loss durability, production signing, product GUI setup or Windows agents.
