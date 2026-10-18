# ADR 12: offline raw disk growth with explicit completion

Status: experimental implementation with named-host qualification (private development record omitted).

Provide grow-only virtual capacity changes for a registered stopped VM under its
cooperating writer lock. Keep the same disk inode and all existing data. Reject
shrinking, unsafe aliases, ambiguous configuration, unexpected disk length and
unfinished runtime ownership. Growing a raw container does not enlarge a guest
partition or filesystem and does not establish guest disk health.

Changing disk length and configuration is not a two-file atomic transaction.
Before mutation, preserve exact original and target configuration sidecars and
durably commit a bounded growth intent under an anchored directory descriptor.
Bind VM/transaction identity, safe disk basename, original inode/length, target
length and configuration hashes. Only then extend the already-opened disk FD,
flush and verify it, commit configuration with anchored rename/readback, and mark
the operation completed. Retain the original metadata and operation evidence.

Check free space on the retained filesystem before preparation and commit,
leaving a 1 GiB reserve plus bounded metadata overhead. Sparse virtual capacity
does not reserve physical space for future guest writes. Reject growth on an owner
that has already issued an inherited lease; runtime and growth reservations share
one purpose mutex. Every commit attempt consumes its permit, including cancellation.

Before a durable pending intent exists, preparation cannot mutate disk or current
configuration. Failed preparation may leave preserved sidecars, but those files
alone do not block a fresh ordinary owner. After pending intent, failures require
review or explicit completion. A failure after completed-record rename can already
leave completed bytes; report uncertainty and validate actual state rather than
claiming that every error leaves pending metadata.

An interrupted, malformed or unsafe intent rejects all ordinary cooperating
writers even when the kernel lock is free. No automatic retry, shrinking, rollback
or intent clearing occurs. The explicit finish command accepts no new disk path or
size; it validates the same pending transaction, sidecars, inode and either exact
old or target configuration/length. Its purpose-bound recovery lease cannot launch
a VM or reconstruct runtime authority. Unexpected state remains preserved for review.

At commit, verify the exact target configuration. Later completed-intent admission
must bind the critical VM/disk identity and target size while permitting legitimate
media, name or hardware-setting changes that preserve those facts. Configuration
hashes remain historical evidence. A subsequent growth preserves the completed
record before replacing it with another pending operation.
If a prior attempt already preserved that completed record, reuse only a stable,
private, single-link archive with byte-exact contents and actual file/directory
flush. Never overwrite a conflicting or unsafe archive.

Expose a read-only doctor classification and CLI grow/finish commands only after
the storage and Core boundaries pass fault tests. The initial UI remains gated.
Acceptance covers seeded-data preservation, sparse zero tail, exact backups, one-shot
operation claims, writer/runtime rejection after interruption, hostile metadata
and alias/replacement cases, and failures at every mutation/flush boundary. Fsync
and orderly recovery tests do not establish host power-loss or guest-filesystem
consistency. Keep those claims experimental until separate campaigns pass.

Persistent identity must survive a mount-number change without weakening an opened
operation's replacement checks. New growth records use schema 2: descriptor-read
filesystem UUID and inode for directory and disk, with matching nonzero UUIDs.
The kernel reply must include the requested UUID and exact bounded layout; missing,
default, malformed or unsupported results reject. Current descriptor device/inode
facts remain pinned before and after each operation. Legacy schema 1 retains its
original strict device/inode checks, including pending recovery and completion.

The internal explicit completed-record upgrade requires a normally admitted writer
and the full old proof. Preserve a distinct exact schema-1 archive before publishing
schema 2, open the disk read-only and revalidate current configuration, sidecars,
length and descriptor identity throughout. It must never waive a legacy device
mismatch, automatically upgrade pending work or rewrite a conflicting archive.
The explicit product Core/CLI operation adds read-only eligibility inspection,
canonical VM/transaction IDs and a required compatibility acknowledgment. Mutation
requires an already-existing safe writer lock and the canonical inactive runtime
history/matching settled intent rule. It captures exact registration, journal,
sidecar and runtime bytes and file bindings, then rechecks them under the actual
owner before archiving, before publication and after publication. Inspection grants
no authority and does not create a missing lock. A free lease alone is insufficient.
The ordinary doctor report remains unchanged and exports no confirmation IDs;
those IDs appear only in the dedicated eligibility response.
Schema 2 deliberately refuses older binaries, so returning to an earlier app after
new growth or an explicit upgrade is not a rollback path for that journal.

Injected historical mount numbers are regression fixtures, not physical remount
evidence. Qualification needs a fresh disposable APFS image with all owners closed
across ordinary detach/reattach, unchanged UUID/inodes/journal and a genuinely
changed mount number, followed by normal admission and further seeded growth.
The preserved Windows VM and host boot volume must not serve as that fixture.

The manager's fresh disposable APFS run 2 passes that exact completed-schema2
changed-device remount, ordinary owner admission and further raw growth, with
unchanged volume UUID/inodes/seeds/metadata files and exact prior journal archive.
All owned commands and the outer parent exit/reap normally; both images detach
normally and remain preserved. Run1's failed directory-status-time assertion is
retained. The revised predicate treats cross-detach directory status time as a
diagnostic, while retaining every other directory binding fact and all regular-file
facts except device; run 2 also preserves directory status time. This is a named-host
APFS image result, not pending recovery, host reboot, power loss or guest health.
The new product upgrade regression suites pass within the integration run of 977
reported tests. A separate signed CLI campaign passes all 12 expected command
exit/reap/EOF outcomes on a fresh synthetic legacy fixture, including refusal
preservation, exact legacy archive, actual upgrade and later growth with a 1 GiB
zero scan. Its corrected process runner first passes 11 separate inert cases.
Native UI acceptance and any preserved-VM migration remain separate work.
