# Project-owned formats

VM directory suffix `.macopenvm`; configuration.json is UTF-8 Codable JSON,
schemaVersion 1 with UUID identity, display name, guest/architecture, backend choice,
CPU/memory, boot description, disks and explicit network policy. Backend preference
is a plain enum, never a concrete VZ/QEMU object. Identity and EFI variables persist
independently. No secrets in JSON. Configuration parser rejects oversized files,
unknown schemas, invalid resources or unsupported guest/backend combinations.

VM-contained disk paths are relative single file components, with symlink checks;
external user-selected media paths are local absolute file URLs with explicit
consent. Disk format is existing raw initially; virtual size and allocated size are
different. Launch preflight rejects hard-linked writable disk/EFI files, unsafe
POSIX write bits, symlink leaves and non-regular files. Writer locks require a
private, regular, single-link file in an owned directory. Read-only inspection can
still inspect hard-linked disks. These checks do not close same-user replacement
races or establish ACL policy; see ADR 3. runtime.json is separate versioned advisory
history; lock/backend observation establishes actual ownership. Never mark a guest
cleanly stopped after forced exit or infer filesystem consistency from a record.

Runtime schema 1 (maximum 4096 bytes) contains a run UUID, monotonic sequence
within that run, advisory wall-clock epoch time and a fixed state/operation/backend-
active/outcome snapshot. Outcomes are pending, guestStopped, forcedStopped and failed.
Stop outcomes require an inactive backend and stopped model. Actual typed
termination observation determines successful guestStopped/forcedStopped outcomes;
sticky runtime failures win. A late force request cannot relabel an earlier ordinary
runtime exit, and explicit forced termination does not prove guest quiescing.
The native stop-order correction (private development record omitted) also
records final failed history when a delegate clears the initiating operation
before the native call throws, while preserving a genuinely newer operation ID.
Apple's production driver confirms force only on successful native completion
plus fresh inactivity; native errors and confirmed force resist late guest downgrade.
No path, name, MAC, credential, diagnostic text or guest content is stored. A durable
starting-history record precedes backend start in the existing controller workflow.
The experimental recorded QEMU producer also flushes ownership intent and binds its
permit before launch; general GUI/Apple adoption remains pending. Records are
serialized through Core; writer ownership covers final persistence. Each new owner archives the prior valid bytes
exclusively as runtime-<validated run UUID>.json, then atomically updates runtime.json.
Archive collisions with different bytes, unsafe files and unknown/corrupt schemas
are preserved and block launch. There is no automatic history pruning or disk repair.
Archive reuse also requires safe ownership, a single link and safe write bits.
Any persistence error faults that history owner; later writes are refused so an
uncertain commit cannot reuse its sequence or overwrite potentially committed bytes.
Permit-bound history uses the actual intent session UUID and retains that permit.
The permit's one-shot history binding stays consumed after a failed open; a prior
record with the same session cannot be reopened with a reset sequence. Without a
permit, history opens only when intent is absent. A matching settled intent may
admit the writer lock but still needs a newly begun permit for runtime history.
Legacy no-intent history retains its independently generated UUID. See
Core intent integration (private development record omitted). The package
recorded settlement boundary (private development record omitted)
seals the actual committed final history and checks bounded exact readback before
issuing a retained-source receipt. Ordinary process exit is not guestStopped;
physical closure may settle honestly failed or forced history. Apple reports typed
observations but does not implement the new settlement receipt.

Stopped-only installation-media editing requires private 0600 schema-1 registration
without unknown or duplicate top-level keys. Only the installationMedia selection
changes; the exact original bytes are retained exclusively as
configuration-media-backup-<transaction UUID>.json. No-op keeps original formatting
and creates no backup. The selected image must be a local absolute nonempty regular
file, but file selection does not validate its format, architecture or bootability.
The CLI exposes attach-media/detach-media and the app uses the same transaction.
No backup is pruned automatically; uncertain commits require read-only inspection.

The optional schema-1 `supportMedia` path is distinct from `installationMedia`.
New binaries decode older configurations with this field absent. Older binaries
are not promised to accept it. Fresh creation can select one additional data image,
always attached read-only to the guest; it never substitutes for boot media or
claims successful setup. The bounded local absolute path is inspected as a
readable nonempty 512-byte-aligned regular image before destination creation.
CLI validation/start and desktop start recheck the input. Stopped support selection
uses the same expected-identity writer admission as installation media, with
`configuration-support-media-backup-<transaction UUID>.json` retaining exact original
registration bytes. Backup and committed replacement readback are required; no-op
preserves bytes and creates no backup. The CLI exposes attach-support-media and
detach-support-media. Experimental desktop Tools Image controls call the same
transaction; they do not launch guest setup or establish installed-agent health.
Other metadata transformations
preserve the field; see [ADR 14](adr/0014-read-only-support-media.md). Input checks
do not authenticate image contents or retain its identity across future runtime.

Experimental direct-kernel Linux argument editing changes only the existing
kernelArguments quoted token. Exact original registration bytes are preserved as
configuration-boot-backup-<transaction UUID>.json under the retained matching
writer. Storage independently rejects any other byte/field change, refuses
runtime/growth/inherited purpose conflicts, and flushes/readbacks the private
exclusive backup before anchored replacement. This is a single-file metadata
transaction; disk, kernel/initramfs contents and platform identities are unchanged.
An uncertain post-rename error may already have committed the target. No automatic
retry/rollback exists. Selection does not verify a root identifier or installed OS.
See boot-argument evidence (private development record omitted).

Paired direct-kernel selection can instead replace exactly the existing kernel,
initialRamdisk and kernelArguments string tokens together, using the same protected
backup/replace contract. Readable selected files are not authenticated or proven to
match one another; see paired-selection evidence (private development record omitted).

Experimental offline raw-disk growth uses `disk-growth-intent.json`, a bounded
flat record (maximum 4096 bytes). Schema 1 remains readable with its exact legacy
device/inode checks. New operations write schema 2, adding canonical nonzero
`directoryVolumeUUID` and `diskVolumeUUID` strings to the original fields. It binds VM and transaction identities,
pending/completed state, directory and disk device/inode, disk basename, old and
target capacity, exact original/target configuration SHA-256 values and derived
private sidecar basenames. Unknown or duplicate fields, including escaped aliases,
unsafe files and unsupported states reject admission. The exact original and
target configuration sidecars are flushed before a pending intent can authorize
disk mutation. The target changes only the `diskBytes` numeric token; other bytes
remain identical. Completion follows disk flush, anchored configuration replacement
and exact readback. Sidecars and historical completed records are retained.

Schema 2 uses descriptor-read filesystem UUID plus inode as persistent identity;
mount device numbers remain historical diagnostic fields. Directory and disk must
have the same recorded and current volume identity. An active operation separately
pins its current descriptor device/inode facts for its entire lifetime. Unsupported
or incomplete filesystem UUID queries fail closed. Schema 1 never gains an
inode-only or changed-device fallback, and recovery completion preserves its
original schema. Older binaries reject schema 2; an older app cannot be used to
open a VM after it has a schema-2 growth journal.

An internal explicit metadata-only upgrade can replace a completed schema-1 record
only while its entire original device/inode proof still validates under an actual
ordinary writer. It preserves exact prior bytes in
`disk-growth-<transactionUUID>-schema1-completed.json`, flushes that archive, then
atomically publishes schema 2 with the same transaction and disk/configuration
facts. It opens the disk read-only. It cannot repair a legacy record whose device
proof already changed after remount, and is not an automatic migration. The explicit
product Core/CLI path additionally requires canonical expected VM and transaction
identities, compatibility acknowledgment, a safe existing writer lock and canonical
inactive history with matching settled intent. Exact captured file bytes/bindings
and stopped-state evidence are rechecked under that owner before and after archive
and publication. Read-only eligibility creates no lock or authority, and exports
confirmation IDs only when eligible; the ordinary doctor format remains unchanged.
No preserved VM was upgraded by this source change.

Pending growth blocks normal cooperating writers even after the kernel lease is
available. Explicit completion validates the same plan, private disk inode, exact
sidecars and either the old or target disk length/configuration. Its actual
purpose-bound recovery lease cannot launch a VM. Completed admission checks
critical VM/disk identity and target size while permitting later media/name/resource
changes. A completed file, available lock or successful flush does not prove guest
filesystem health or host power-loss qualification. Doctor reports fixed findings
without exporting transaction identities, paths or sidecar content. See
[ADR 12](adr/0012-offline-raw-disk-growth.md).

configuration.json is the new-VM registration marker. Before committing it, shared
creation code checks host availability, creates only a new directory, and flushes
disk/platform identity files. An interrupted directory without this marker is an
incomplete creation, preserved for inspection rather than silently recreated.
The Apple experiment uses machine-identity.bin and efi-variables.bin; identities
are not reset on open. No installed guest-data or power-loss guarantee is inferred
from the current live-media tests.

No historical installations were found in this empty workspace. No legacy paths
or identifiers are replaced. Future migrations must inventory and preserve guest
disks, snapshots, platform/MAC/TPM identity, pairing and user settings, with fixtures
and last-good rollback. v1 is initial format; no fictional prior migration exists.

Benchmark schema v1 and generated SPDX 2.3 records are separate public formats.
Guest protocol remains a design document until generated host+guest decoders and
conformance tests exist. No proprietary VM/disk import compatibility is claimed.

Development packaging writes build/build-manifest.json, schema 1. It records the
requested debug/release profile, version/revision, Swift/SDK/architecture, and hashes
of the signed CLI/app executable. Sources are a sorted list of repository-relative
paths, sizes and SHA-256 hashes for production Swift and the package/build/signing/
license/inventory recipe; its SHA-256 covers canonical sorted compact JSON. Input
snapshots before and after packaging must match. The benchmark requires a bounded
regular record and verifies current sources, CLI bytes and actual minimal signature
before launch; each trial also rechecks the source/artifact hash.

This local record is advisory provenance, not a signed attestation, clean-source
certification, complete application-bundle digest or bit-for-bit reproducibility
claim. A local attacker able to replace both a binary and its record is not excluded.
Concurrent source changes during compilation and concurrent packaging remain
unsupported; build with stable inputs. Each benchmark uses an exclusive unique
result filename and private .lab session. Existing historical reports are preserved.

Doctor output is a separate schema-1, bounded structural report: controlled status,
cooperating writer probe, fixed file roles with stat metadata, findings and explicit
limitations. It excludes VM names, paths, UUID/MAC, file contents and pairing data.
Its additive history field reports notRecorded, writerHeld, guestStopRecorded,
forcedStopRecorded, failureRecorded, interruptedOrUnreconciled or invalid. It exposes
no run UUID, timestamp or raw record. An available lock plus pending history is
interrupted/unreconciled; force/failure/invalid records require review. A guest-stop
record is host-observed lifecycle evidence, not guest filesystem verification.
It is a point-in-time diagnostic, not a runtime journal, native-platform validation,
filesystem checker, backup manifest or repair command. No files are changed.
Its additive intent field reports unavailable, notRecorded, unsettled, settled,
identityMismatch or invalid, comparing saved VM identity without exporting IDs.
Unsettled or invalid intent requires review even after lock release; matching
settled metadata does not prove clean guest shutdown or disk consistency.

Runtime-intent schema 1 is an experimental Storage implementation, distinct from advisory
runtime.json. Its bounded flat UTF-8 record has exactly schemaVersion, vmID,
sessionID and state (unsettled or settled), at most 4096 bytes. Duplicate/unknown
keys, nesting, invalid types/UUIDs, unsafe aliases and unknown versions are rejected.
Admission is checked while holding the writer lock: an unsettled record always
blocks a replacement writer; a settled record also requires the caller's matching
expected VM identity. An available kernel lock does not clear unresolved intent.

Beginning a session must flush the file, atomically rename within the retained
directory anchor and flush that directory before returning an in-memory permit
bound strongly to the actual VMLock. A copied disk-recorded UUID cannot recreate
that permit. Ambiguous persistence freezes the owner. Matching identity admission,
shared history binding and read-only classification are verified narrowly in
Core intent integration (private development record omitted). The
experimental recorded QEMU producer/settlement (private development record omitted)
uses package-only actual-source/permit/session receipts. Storage compares and
fsyncs the same-anchor final history, commits settled intent with file/directory
flush and exact readback, and rechecks history/owner identity. Commit failure
retains recovery custody and cannot retry; a post-rename error may already leave
settled bytes. Public disk UUIDs never recreate this authority. General backend/UI
adoption and recovery after worker death remain pending. This format does not
establish worker crash recovery, disk health or power-loss durability acceptance.
Narrow parser/admission/permit tests and actual CLI rejections are recorded in
runtime-intent evidence (private development record omitted).

The experimental [runtime-worker protocol](runtime-worker-protocol.md) is a local
host-control format separate from guest-agent messages. A four-byte big-endian
length prefixes fixed version-1 request/response payloads of 56/64 bytes, capped
at 128 before allocation. Reserved bytes, known enums, canonical booleans and
nonzero increasing request IDs are strict. Fresh matching status establishes
revision even on a controlled runtime failure; each mutation consumes that status.
Core compares actual VM/session/revision and reserves pending state before await.
Experimental normal stop adds command byte4 while retaining the existing fixed
packet shape and opcodes. Older private workers reject it; no support negotiation
is inferred. Request acknowledgement preserves stopping state and ownership until
actual guest termination and durable settlement, and an opaque exit remains failed.
Client EOF/timeout/cancel closes transport only; reconnect does not replay commands
or reconstruct owner authority from UUIDs/PIDs. One native client-parent loss trial (private development record omitted)
passed same-session reconnect, writer exclusion and final receipt settlement;
broader worker-loss recovery, GUI integration, minimum-host and persistent Windows remain open.

The paused hard-loss trial (private development record omitted) preserved
unsettled intent and paused pending history even after public QMP cleanup freed the
kernel lease. The actual enabled Storage test rejected matching and nil-identity
VMLock admission and verified bounded inventory/hash/identity stability. No new
worker result or recovered receipt changed those records. Pair lease retention
does not provide individual-child terminal/drain evidence or permission to settle,
clear, adopt or replay an interrupted session.

Single-survivor hard-loss evidence (private development record omitted)
likewise leaves unsettled intent and failed-active history unchanged after public
cleanup frees the lease. Actual Storage rejects matched/nil identity admission.
The separate lab producer's first-exit/60-second fallback markers are fixture
records, not production commands, receipt constructors or permission to adopt an
orphan PID. The TPM and repaired QEMU trials retain different exact producer/binary
pins; neither recovers the survivor's terminal/drain evidence or writes settlement.

## Stopped hardware settings

Schema 1 retains its existing cpuCount and memoryBytes fields. The hardware
transaction changes their numeric tokens only; all other registration bytes are
preserved. A changed save creates one exclusive private
`configuration-hardware-backup-<UUID>.json` containing the complete prior bytes.
That prefix is reserved from disk filenames. Admission consumes the matching
writer's metadata reservation and rejects unsettled runtime/disk-growth intent.
The new registration is atomically renamed, directory-flushed and read back.
After an uncertain commit, inspect actual registration and backup; no automatic
rollback occurs. A stale editor must reopen its snapshot. This does not change
firmware/TPM identity, disks, media or network settings. See
[ADR 17](adr/0017-stopped-hardware-settings.md).

## Stopped networking settings

Schema 1 retains the existing `network` scalar and `macAddress`. A network save
replaces only the network value token, preserving every other registration byte,
including formatting and escaped keys. An actual change creates an exclusive
mode-0600 `configuration-network-backup-<UUID>.json` with the exact prior bytes;
the prefix is reserved from guest disk names. No-op creates no backup. Matching
noninherited writer admission and runtime/growth checks precede the save; backup,
atomic rename, directory flush and readback follow the same protected transaction
contract as stopped hardware settings. Uncertain saves preserve evidence and do
not attempt rollback. Shared edits require Linux/AppleVz; saving disconnected
metadata for other configurations does not qualify their network/backend. No
MAC, disk, firmware, TPM or guest credentials change. See
[ADR 21](adr/0021-stopped-networking-settings.md).

## Saved VM navigation references

The application preference key `macOpenVM.savedVMs.v1` contains JSON Data with
`schemaVersion: 1` and an ordered `entries` array. Each entry has configurationURL,
vmID, name and guest; the URL is a canonical local `configuration.json` file.
Names are bounded to 128 UTF-8 bytes, paths to 4096 bytes, the entire document to
256 KiB and the list to 50 entries. Most recently opened entries come first;
same-path references are updated without collapsing distinct locations that have
the same VM UUID. Search uses the display name and containing-folder name.

Unknown versions, duplicate locations, invalid URLs, malformed documents and
oversized data disable library updates without replacing the stored preference.
Missing VM files do not erase references. Forget removes a reference only; VM
files and runtime history are untouched. These preferences are convenience data
managed by macOS, not a crash-atomic or cross-process VM registry. Runtime truth
comes from the actual owner, not this document. No timestamps, thumbnails, guest
content or credentials are stored here. See [ADR 18](adr/0018-saved-vm-library.md).

## Agent protocol v1 health evaluator

`GuestAgent/Protocol/schema.json` generates canonical fixed-width Swift/C codecs.
The 16-byte network-order header is magic MVOA (u32), major/minor (u16 each),
type (u16), reserved zero (u16), and body size (u32). The maximum whole frame is
4 KiB. Every body starts with session16 bytes, sequenceu64 and request16 bytes.
Hello adds VM16 bytes and supported/required u32 feature masks; only health bit1
is implemented. HelloReply returns identity, selected features and four u16
agent-version/architecture fields. HealthRequest carries only the common fields;
HealthReply returns version/architecture and u32 status. Rejection has a u32 reason.
Known shapes remain fixed across minor versions; unknown kinds/major, truncation,
extra bytes and conflicting lengths/reserved bits fail. IDs carry no pairing secret.
TLS authentication, state/sequence admission and credential custody are separate
from byte decoding. See [protocol scope](guest-agent-protocol.md).

## Experimental Linux installer generations

The Alpine/OpenRC setup evaluation uses a root-private account reservation at
`/var/lib/macopenvm-agent-account/record`. Its canonical 12-line record binds one VM UUID,
locked nonlogin UID/GID, account-row hashes, credential-retention state and four
enrollment hashes. This reservation survives both uninstall modes. It does not
authorize account adoption, repair, key rotation or a different VM. The new manager
uses the `macopenvm-agent-account-v2` marker in installed, retained and removed
states. Earlier native installation proofs used v1; new code refuses that legacy
record before creating its kernel lock. No reservation migration is implemented.

The new compatible-manager transaction source uses v2 ownership state at
`/var/lib/macopenvm-agent`, with exactly `owner`, `payload.sha256`,
`enrollment.sha256` and `generation`. The canonical six-line generation record
identifies its VM, current approved manifest hash, one prior manifest hash or `-`,
manager hash and init-script hash. A/B managers and init scripts must be identical.
Legacy v1 installed state is preserved and refused; no migration is implemented.

The permanent root-private empty `macopenvm-agent.kernel-lock` file is never
removed or replaced. Actual descriptor-held kernel exclusion authorizes a current
mutator; the file's existence and any journal or PID do not establish ownership.
Program and state siblings use fixed `.next`, `.previous` and `.failed` slots.
The private `macopenvm-agent.install-lock` directory retains the canonical
12-line transaction record: operation, VM, source/target manifest hashes, manager,
UID/GID, reservation hash, source/target state hashes and phase. Names from record
contents are never filesystem paths. Recovery requires explicit VM and both
generation pins plus the exact admitted pre/post namespace for that phase.

Completed upgrade/rollback records and bounded operation/phase recovery archives
are retained. Partial, changed, duplicated or unrelated entries cause refusal;
occupied generation history blocks another upgrade or ordinary uninstall. The
record is development installer metadata, not a stable product updater API.
Fault tests and native generation qualification are still pending. See
[ADR23](adr/0023-linux-agent-installation.md) and
static preparation (private development record omitted).


New compatible-manager payload admission follows ADR27: the signed v1 canonical
three-file manifest remains unchanged, with maximum512bytes; agent16MiB,
initd16KiB and manager128KiB are distinct host/installer limits. Host verification
and CLI reads enforce these per-file limits before accepting payloads. Credential
limits remain64KiB. Previously qualified65,267-byte manager/packages and their
evidence remain historical, with no automatic manager migration. The proposed
retirement journal/archives are experimental and require qualification before any
product claim. See [ADR27](adr/0027-linux-generation-retirement.md).


Retirement source defines a separate fixed19-line ASCII v1 journal (at most2048
bytes): VM/retirement UUID, current/failed pins, manager/service digests, account
IDs, reservation/current-state/failed-state/cohort digests, source directory inode
identities and one bounded phase. The canonical prepared record is staged in the
adjacent retirement.next directory before any flush. Complete private paired
archives retain failed program, state and generation journals; completion is a
separate canonical confirmation, with observed unconfirmed publication retained
for explicit resume. The max8 pair limit refuses overflow rather than pruning.
Historical archive validation is independent of later current generation, service
files, credential bytes and mutable reservation status. These new retirement
formats are not yet qualified by the full recovery/native campaigns.

## Bundled Windows worker descriptor

`Contents/Resources/macopenvm-worker.json` is sealed into the app after its fixed
sibling `Contents/MacOS/macopenvm-worker` is signed. Schema 1 has exactly five
fields: `bytes`, `identifier`, `schemaVersion`, `scope`, and `sha256`. The scope is
`macopenvm-bundled-worker`; the identifier is the actual app identifier plus
`.worker`. Packaging emits sorted, two-space-indented UTF-8 JSON with one trailing
newline. The descriptor is at most 1,024 bytes and its helper at most 128 MiB.

The app derives both locations from its actual bundle, verifies the outer seal
and fixed code identifiers, then compares canonical descriptor bytes against the
actual helper hash and length. Private no-follow file reads and stable file/folder
identities bind the checks. A descriptor contains no executable path, arguments,
session, PID, credentials or launch permission. Only current native bundle
admission produces the non-serialized reviewed helper value; configuration and
preferences cannot select a replacement. Development ad hoc signing does not
establish release publisher trust or notarization.

## Registered Windows runtime records

The worker uses a new VM-contained `.runtime/run-<32 lowercase hex digits>` folder
and a new private `/private/tmp/mvo-qemu-<16 lowercase hex digits>` endpoint folder.
Registered worker/display/result records use separate schema 1 scopes:
`macopenvm-registered-qemu-worker-route`,
`macopenvm-registered-qemu-display-route`, and
`macopenvm-registered-qemu-runtime-result`. Display records additionally bind
actual endpoint parent/socket device and inode values. Saved routes correlate
the current actual worker; they cannot launch one or reconstruct writer custody.

The result distinguishes outcome, child exit/signal status, completed child
output drains, platform-state flush, resource revalidation and settled intent.
An App parent's private regular stdout/stderr files have descriptor closure,
which is distinct from the QEMU/TPM pipe EOF/drain proof. A missing or failed
producer result remains a failed advisory even when the parent exits with status 0.
Neither record existence nor a `forcedStopped` result proves clean guest shutdown.
