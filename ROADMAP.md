# Roadmap and measurable exits

Current maintainer priority: Windows hardware rendering at the actual Mac guest
viewport, with a 120 Hz target on this host. Qualify 3840×2160 separately; a 4K
option does not prove the native viewport applied. Measure guest workload,
transport arrivals and native presentation independently, including p95/p99
stalls. Preserve menu-only controls and automatic capture through the tests.

App79 is normally closed with the preserved VM settled; see the
current handover (private development record omitted). The signed driver and frozen
wire2/ABI1 host pair now report native3456×2168 at120Hz. Shared Metal delivery,
separate Mac presentation feedback and active-Space visibility checks are in use.
The full-display shader's20-second fullscreen sample delivers107.1 Mac
presentations/s; its3456×2169 drawing buffer has an extra CSS-rounded row.
Sustained120FPS, exact-native-height shader work, gameplay and physical panel
scanout remain unqualified. Earlier55.7/s gameplay is a separate workload and
must not be relabelled by the shader result.

Next graphics work attributes producer readback and pacing, verifies bounded
cached-frame retry and repeats a controlled game scene. Keep the current binary
closure preserved until independently verified candidates pass admission and
normal lifecycle checks. A row-copy candidate showed no consistent improvement
and is not being admitted. See [Metal surface delivery](docs/adr/0043-metal-surface-delivery.md)
and the handover for existing lifecycle and performance limits.

The current manager iteration also addresses visible library actions, safe New/Open
sheet transitions, held-key and desktop-Space input bugs, actionable Windows
readiness and ordinary launcher graphics settings. Useful audio playback and
durable disk-growth identity across host remounts remain priorities. The tester
actively searches for bugs and verifies developer fixes independently. Feature
completion requires the acceptance evidence below and in FEATURE_MATRIX, including
the remaining guest integration, storage, networking, accessibility and release gates.

The next CLI slice adds explicit controls for an existing registered Windows
worker under [ADR33](docs/adr/0033-existing-windows-worker-cli-controls.md). Verify
private route/session admission, status-before-command revision, explicit Force
Stop confirmation and unchanged owner custody with real local IPC tests. Build
the ordinary CLI and verify read-only status on the current live worker; do not
infer shutdown from an acknowledgement. Other backend routes and native lifecycle
completion remain separate acceptance work.

Order follows the supplied specification. Earliest unmet milestone: **0**.
Blocked Windows/graphics work does not excuse speculative code or false support.

| Milestone | Ordered work | Acceptance criteria |
|---|---|---|
| 0 | Probe; public capability map; Linux native boot/display/input; compliant Windows HVF feasibility; graphics/network/storage/distribution ADRs; baseline | Major unknowns named, actual ARM64 guest boot proven, backend/device/version recorded; Windows feasibility remains open until actual compliant boot; schema and honest baseline captured |
| 1 | Versioned config/state; storage/locking; CLI lifecycle; serial; explicit NAT/offline; crash recovery | Invalid transitions safely fail; repeated real-guest cycles; two writers excluded; forced failure preserves data; contracts and recovery tests pass |
| 2 | Accessible native library/assistant; display/input/fullscreen; validation and redacted logs; Windows/Linux install | New user installs both guests without terminal; desktop D1–D7 and accessibility audit pass on named matrix |
| 3 | Generated authenticated protocol; Windows service/session + Linux daemon; resize/time/shutdown/folders/clipboard/audio; unified installer | D8–D10, malicious messages, reconnect, upgrade/downgrade and rollback pass in real guests |
| 4 | Integrity-proven snapshots/clone/templates; open import/export; forwarding/multi-display/device/backup diagnostics | Disk-full, power-loss, interrupted copy, corrupt metadata and restored guest data pass; unsupported hardware clearly reported |
| 5 | Evidence-selected graphics; seven seamless stages; compatibility/performance publication | Real renderer identified without software fallback; correctness/performance apps pass; seamless focus/IME/UAC/modal/multi-monitor/reconnect soak passes before supported status |
| 6 | Security/accessibility reviews; reproducible dependency builds; signed/notarized installers; SBOM/license onboarding; RC soak | Stable-release gates in PRODUCT_SPEC all pass; no unresolved high/critical issue; clean-machine build and installation verified; no secrets exposed to PRs |

## Current vertical slice

The probe, schema-1 validation/state model, sparse disks/locks, headless Linux
console and initial EFI display/input path have executed; see
native evidence (private development record omitted). Five uncontrolled
baseline trials are recorded. Milestone 0 remains open for compliant Windows
feasibility and the full installed-guest/display acceptance.

The Linux creation assistant now shares the CLI transaction. Real GUI create →
start → verified console interaction → guest poweroff → disk-lock release passed
on the named host. Unsafe CPU allocation created no files; duplicate creation
preserved configuration, identity, EFI variables and disk. Complete installation
acceptance remains open.

Capture Input now reacquires the actual native view after Release Input; a real
guest command and clean shutdown passed. Fullscreen notifications filter the owner.
Storage tests and seven CLI failure cases reject FIFO/special files, unsafe writer
locks and hard-linked writable disk/EFI files before native start. A real release
guest still boots and retains writer exclusion through shutdown. Same-user path
replacement races and power-loss recovery remain separate gates.

The explicit shared-network fixture has retained its configured MAC across real
boots, acquired DHCP/default route/DNS and completed a certificate/hostname-checked
HTTPS request. The serial contract verifies guest Ctrl-C, restoration of terminal
mode settings, clean exit and writer release. Initial harness failures and private
evidence are retained. Inbound exposure, forwarding conflicts, network performance
and broader host/guest versions remain open.

Read-only doctor now reports incomplete/corrupt registration, unsafe file metadata,
configured media and cooperating ownership. Seven tests and four signed CLI reports
prove narrow preservation/privacy behavior; no lock is created or data repaired.
Native identity/EFI semantics and guest filesystem integrity remain separate gates.

Three real boots, a bounded guest write/flush and a scoped runner crash (private development record omitted)
preserved the known sector, disk size, configuration and machine identity. Live
ownership excluded a second writer and was released after confirmed runner exit.
This is a storage-device/failure contract, not installed-OS or power-loss proof.

Build provenance and benchmark preservation (private development record omitted)
passed both profiles, 11 Python checks and two real release trials. Historical debug
evidence is unchanged; new reports use exclusive unique paths and accurate profile/
source/binary hashes. No unlike-profile regression comparison is made.

Advisory lifecycle history (private development record omitted) passed
real clean/crash classification, prior-byte archives and two desktop owner sessions.
Bounded metadata mutation tests (private development record omitted) cover
12,000 inputs and all inconsistent recorded-stop combinations without opening
decoded paths. These narrow slices do not close recovery or security acceptance.

Completed source hardening: reject unsafe equal-byte archives, drain failed-launch
history while retaining any active backend, return nonzero for backend failure,
avoid implicit force stop on cancellation, reject false start/stop completion and
protect the active/settling owning window from closure. Fault/cancellation tests
and strict packaged builds passed; current-release close/quit/cancel/input/guest-stop
ownership checks passed narrowly. macOS 14 and full recovery campaigns remain.

Current desktop slice also adopts the user-required native Liquid Glass controls,
status and navigation on macOS 26+, with semantic solid accessibility and older-host
fallbacks. Acceptance: current strict builds, actual welcome/creation/stopped/active
interaction, unchanged guest input/ownership, readable light/dark appearance and
contrast/transparency/keyboard audit. Older-host runtime and full accessibility
acceptance require their own evidence.

Then complete a persistent Linux install/display slice on a NEW disposable EFI VM.
Shared stopped-only ISO attach/detach now has atomic changes, exact private backups,
13 targeted tests, a signed-CLI contract and actual desktop menu/button/picker
preservation; selected-media compatibility remains unverified. Install only through lawful
signed packages with explicit networking; prove ISO-free disk-backed boot, a saved
test file over restarts, graphical login/application/input and clean stop. Terminal
installation evidence alone does not meet the guided no-command-line GUI requirement.

## Dependencies and stop conditions

The maintainer reiterated Windows as the primary target. Foreground work now
prioritizes its protected ARM64 firmware/TPM path. Pinned tools and firmware/probe
builds (private development record omitted), actual HVF-only initial
EFI/TCG2 execution, a narrow TPM NV restart/scoped-crash marker, and positive
public-test trust-chain/signed-image execution passed. Authentication enforcement,
Microsoft trust/revocation, TPM identity/PCR/power-loss evidence and actual Windows
installation/driver health remain open. Selected English media failed its source
checksum association; bounded payload metadata diagnosis is the next media step.
In parallel, evaluate an original no-OS framebuffer/input proof using the exact
candidate, explicit mode dimensions and actual device acknowledgements. This
acceptance is a prerequisite experiment; Windows desktop acceptance remains B2/D1–D4.
The minimum-host audit (private development record omitted) found that the
current executable requires27 and thirteen mandatory libraries require26. A
separately targeted14 build needs a compatible dependency closure, weak-import/API
inspection and actual14 loader/guest tests. Software GIC2/HVF is source-supported
for investigation, not a verified Windows or older-host route. Retain strong
entropy, TPM/PPI and authentication requirements in that evaluation.
These prerequisites never substitute for the required Windows workflow.

Windows requires lawful ARM64 media, verified secure platform and usable native
drivers. Distribution requires maintainer namespace and release credentials, not
ad hoc signing. Graphics requires viable signed driver and legal dependency review.
Snapshot APIs do not alone establish disk snapshot consistency. No milestone
changes these prerequisites. Maintain docs/CHECKPOINT.md at execution limits.

The ADR8 Swift process/QMP slice (private development record omitted)
passed one original no-OS native fixture and six local pair tests/eight cases for
partial launch, failure/cancellation retention and actual terminal/drain/callback
settlement. The original lease-spawn prerequisite (private development record omitted)
passed six fake-child tests; the earlier stalled run remains preserved and
inconclusive. Aggregate check 47183 passed 118 Swift tests with one explicit skip,
18 Python checks and 37 SBOM components before the next integration.

Next application work follows [ADR9](docs/adr/0009-qemu-crash-ownership.md): integrate
lease ownership with durable intent, an independent worker and same-session
reconnection. OwnedProcess/Storage duplication and
two actual QEMU/swtpm parent-close/survivor trials (private development record omitted)
now passed on named APFS host; the normal-QEMU-quit survival assertion remains a
preserved failure. Full check 26304 passed 124 Swift tests with one explicit skip,
18 Python checks, 37 components and three historical benchmark structures.

The new bounded intent admission barrier is qualified at current cooperating Core
entry points; at that revision runtime producer ordering remained to be wired.
Then require real app/worker loss, either actual child surviving,
delayed drains and independent writer probes before persistent-disk adoption. The
completed native trials closed parent descriptors while the CLI owner stayed alive;
they do not establish that hard-crash/reconnect contract. Windows installation,
macOS 14 execution and full guest/desktop acceptance remain separate unmet gates.

The event-driven child monitor (private development record omitted)
passed 22 focused tests and fresh native shared start/pause/resume/explicit-quit
qualification with both terminal/drain outcomes and readonly preservation. Failed
compiler/executor runs are preserved and corrected by nonisolated Sendable bridges.
The unchanged debug host-process harness recorded three trials per revision;
parent CPU medians were 0.055694 and 0.001991 seconds over launch/monitor/exit,
with uncontrolled host load. This is no regression, guest, energy or wakeup claim.
Full check 4680 passed 132 Swift tests with one explicit skip, 18 Python checks,
strict formatting, 37 components and three historical benchmark structures.
Next worker work must expose retained notification uncertainty through IPC, handle
unresolved waits conservatively and implement the intent/reconnect/crash contract;
the settled monitor does not close those adoption gates.

The Storage intent prerequisite (private development record omitted) now
blocks unsettled sessions after kernel-lock release and publishes begin authority
only after an anchored, flushed, identity-checked commit. Ten new Storage tests
and three actual synthetic CLI rejections qualify this boundary. Full check 71863
passed 142 Swift tests/one explicit skip and 18 Python checks.

Core intent integration (private development record omitted) now
checks matching saved identity under the admitted lock, binds history once to the
actual retained permit/session, and reports intent without IDs/paths in read-only
doctor output. The first combined run failed 14 reader-dispatch issues and remains
preserved; the distinct reader passed 17 new tests. Synthetic actual CLI checks
passed six prohibited-command rejections with recorded inventory preservation,
redacted reports and a matching-settled media update with exact backup/protection.
No guest or existing user media was launched or changed. Full check 2795 passed
159 Swift tests/one explicit skip, 18 Python checks, strict formatting, 37 components
and three historical benchmark structures.

The new recorded settlement boundary (private development record omitted)
wires one original no-OS QEMU producer to durable begin, exact retained permit/session,
sealed actual backend/history receipts and same-anchor final-history flush before
settled intent. Final focused 55216 passed 27 registrations; preserved 18061/40455
failures were corrected for local socket permission and callback snapshot timing.
Native 38597 passed original EFI completion and shared start/pause/resume/explicit
quit, both terminal/finished drains, read-only pins, same-session settled intent and
forcedStopped sequence 9, followed by independent available writer probe. Full 88222
passed 186 Swift tests/one explicit skip, 18 Python checks, strict formatting,
37 components and three historical structures. Commit-gate tests prove waiter
cancellation retains custody, failed commit retains recovery without retry, and
successful last-close releases the actual owner/lock.
Review then corrected late force-request relabeling: actual typed termination
observation determines successful outcomes, and sticky runtime failure wins.
Focused 58666 passed 17 tests; final full 95485 passed 187 Swift tests/one skip,
18 Python checks, strict formatting, 37 components and three historical structures.
The earlier native trial remains bound to its original source/CLI pins; no new
native trial was run after this correction.
A final guard rejects duplicate stop callbacks after ownership sealing; its test
keeps the decoded final history record/classification unchanged with no history error. Focused
46158 passed five owner tests and final full 53300 passed 187 Swift tests/one skip,
18 Python checks, strict formatting, 37 components and three historical structures.
Final source pins remain distinct from the earlier native trial.

Matching settled admission still needs a newly begun permit for runtime history;
no-permit history remains limited to absent intent. At that revision independent
worker IPC and hard-loss/reconnect tests remained before persistent Windows adoption and
broader backend/UI receipt wiring. Apple has typed observations, not this receipt
implementation. No automatic clearing or orphan-PID signaling. Hostile path races,
post-rename ambiguity, power-loss recovery and minimum macOS 14 execution remain
separate gates. The native trial did not establish clean guest shutdown or Windows.

Independent worker client-loss continuity (private development record omitted)
now has one actual fresh no-OS trial: checked independent session/private stdio,
client-parent SIGKILL, same-session reconnect and same-writer-file exclusion,
IPC pause/resume, and explicit final receipt settlement. Original strict EFI
completion, both terminal-zero children/finished drains and read-only hashes passed;
history was forcedStopped sequence 9 with matching settled intent. Final kernel
availability was observed after settlement; no orphan-worker exit status or hard
worker-loss claim follows. Independent post-checks preserved source/build/CLI/harness
matches and all 15 recorded checks. Existing GUI/user VM media were not touched.

Final full 89060 passed 204 Swift tests/one skip, 18 Python checks, strict formatting,
37 components and three historical structures. The first capture compile failure,
strict-format failure, unnecessary-try compile failure and late-frame admission
review correction remain recorded. The [fixed host-worker schema](docs/runtime-worker-protocol.md)
is independent of guest-agent protocol and has no replay/PID continuation authority.
At that revision, hard worker loss with actual survivors, lost/delayed observations,
recovery after worker death and broader GUI/backend adoption remained to be qualified
before persistent Windows exposure. Windows remains primary; this CLI no-OS prerequisite does not
close the lawful media/platform/install/desktop, clean guest shutdown, minimum
macOS 14 or filesystem/power-loss gates.

Paused worker hard-loss/admission evidence (private development record omitted)
now adds one fresh original no-OS pair trial. The first attempt failed before
worker SIGKILL on an over-specific QMP mode guard; preserved live IPC cleanup
settled normally. The corrected harness accepts only owner 0600/0700 QMP modes
with peer/private-parent/retained endpoint guards; WorkerIPC remains 0600.
Native 41477 observed registered worker SIGKILL/wait -9, both direct child identities
still live, paused QMP on the same pre-loss endpoint and same busy writer identity.
Public QMP quit made the same kernel lease available; intent/history stayed
unchanged unsettled/paused pending. No child terminal/drain/receipt/settlement
evidence was recovered. Independent actual Storage filter 55744 rejected matching
and nil-identity admission with the bounded inventory unchanged; its default native
fixture skip remains explicit. Production/CLI artifact pins are unchanged.

Final full 56309 passed 204 Swift tests/two explicit skips, 24 Python checks,
strict formatting, 37 components and three historical structures. At that revision,
each individual survivor after hard worker loss, lost/delayed observations and
honest recovery/adoption with opaque evidence remained to be qualified before
exposing persistent disks.
This paused pair trial proves no running guest, Windows, recovered settlement,
clean shutdown, GUI workflow, minimum host or power-loss acceptance.

Native stop ordering (private development record omitted) now uses the
same production Apple MainActor driver with fresh native closures: seven pure
registrations/11 cases, plus Core correction and one actual same-session failed
history case. Confirmed force/native error resist late guest downgrade; a native
call that fails after its delegate ended the operation leaves final failed history.
These are pure/contract tests, not new VZ guest/reference-escape/serial-drain/
receipt/minimum-host qualification.

Single-survivor worker trials (private development record omitted)
now add TPM-only and paused-QEMU-only same-lease retention after exact worker
SIGKILL, followed by public checked cleanup and actual unsettled-intent admission
rejection. The TPM case is pinned to the earlier producer/artifact; the failed
QEMU pre-loss monitor attempt remains preserved, and the repaired QEMU case has
separate final producer/artifact pins. The first child was terminal/drained before
READY; surviving-child terminal/drain/receipt/settlement evidence was not recovered.
Fixed first-exit/60-second lab fallback controls do not become production partial-
fault policy, debug IPC or PID authority. Final full 49714 passed 212 Swift tests/
two skips, 28 Python checks, strict formatting, 37 components and three historical
structures. Next qualify honest recovered observations and opaque post-loss
ownership/adoption, delayed drains and broader UI/backend integration before
persistent disks; Windows remains primary and these no-OS prerequisites do not
close running guest, Windows, GUI, macOS 14 or filesystem/power-loss gates.

The next native display-client slice follows [planned ADR 10](docs/adr/0010-native-qemu-display-client.md).
That link records a plan, not verified RFB/native-window, input or viewport behavior.
It introduces no new Windows support or source/artifact association; the 49714
proof tables remain historical snapshots until new checks and native evidence exist.


## Native QEMU display client checkpoint

The original RFB client passed a fresh diskless native trial with both applied
firmware modes, matching frame samples, eight repeat-key acknowledgements and a
new display epoch after reconnect while the same worker session/writer remained
active. Explicit parent cleanup confirmed both normal child exits and drains,
settled intent and released kernel ownership. See the scoped evidence (private development record omitted).
The VNC-enabled build is a separately recorded evaluation candidate; macOS 14 and
redistribution remain gates. Next prove the visible Liquid Glass app's input,
focus, reconnect and fullscreen behaviour after the Mac is unlocked, then continue
the primary Windows platform/install work when its lawful media and other
prerequisites are available. No feature row became supported from this trial.


## Windows inbox-storage prerequisite

Investigate NVMe through a new original firmware/data fixture before relying on an
unqualified ARM64 third-party storage driver. [ADR11](docs/adr/0011-nvme-inbox-storage-prerequisite.md)
defines acceptance: selected namespace identity and bounds, prepare/write/flush/readback,
actual process exit/drains, independent whole32MiB verification, a new-process
mutation-free verification boot, unchanged file identity/hash and retained writer
exclusion. Existing no-disk/TPM profiles and all user VM/media remain preserved.
Windows StorNVMe loading and actual installation are separate release gates.

The first original NVMe orderly-persistence trial now passed on the named host,
with a preserved failed connection-policy trial. Windows inbox-driver loading and
actual installation remain gated by accepted media/platform prerequisites. Next
integrate only evidence-qualified Windows setup devices; do not promote the original
firmware probe into Windows support or production power-loss recovery.


## Offline disk growth

Implement the shared Windows/Linux raw-container grow-only workflow under [ADR12](docs/adr/0012-offline-raw-disk-growth.md).
Acceptance: preserve seeded original data and inode, verify sparse zero tail and
exact configuration backups, persist intent before mutation, prevent all ordinary
writers after interruption, and finish only an explicitly selected validated pending
transaction. Inject disk/config/marker flush and replacement failures; no shrink,
automatic retry or guest partition/filesystem claim. The CLI and read-only doctor
share this gate; the visible settings flow remains experimental until qualified.

The initial shared Windows/Linux capacity slice (private development record omitted)
now passes actual file/fault/lease/diagnostic tests and fresh CLI trials. A completed
history archive can be reused safely after pre-pending failure, preserving its
inode/bytes. Guest filesystem expansion, physical disk-full/power-loss campaigns,
visible settings and macOS 14 remain acceptance gates; no guest install follows
from these metadata/container checks.

## Persistent Linux installation prerequisites

The protected direct-kernel argument transition (private development record omitted)
now passes exact-backup/token, owner/cancellation/fault and fresh CLI tests under
[ADR13](docs/adr/0013-protected-linux-boot-arguments.md). It is one prerequisite;
the atomic kernel/initramfs/argument selection (private development record omitted)
also passes bounded metadata/lease/fault tests and fresh CLI calls. Selected image
content, matching versions and actual installed-root restart remain unverified.
The retained Alpine virt ISO lacks the stock offline kernel/initramfs package chain.
Acceptance requires a verified package kit, actual package-solver/install success,
matching kernel/modules/initramfs, managed serial ownership, preserved VM identity,
ISO detach and repeated disk-root boots with observed guest poweroff. EFI and GUI
installation remain separate acceptance gates. Windows remains the primary target.

The private 49-package kit (private development record omitted) now passes
archive signatures and signed control/data hash checks, and the serial supervisor (private development record omitted)
passes bounded real-child ownership/deadline tests. These qualify inputs and test
infrastructure; they do not establish solver, package script or installation success.

Next qualify the [separate read-only support image](docs/adr/0014-read-only-support-media.md)
without replacing the live installer image. Acceptance: preserved distinct media
roles, rejection before destination mutation, strict metadata preservation and
writer gates, actual second read-only device/mounted hashes in a fresh offline
guest, and observed shutdown/owner closure with the blank system disk unchanged.
This begins the shared one-support-drive requirement; Windows setup execution,
signed drivers, guest health and installation remain separately gated.

The fresh passive support-image trial (private development record omitted)
now passes actual device read-only state, whole-image/list and 54 payload hashes,
excluded bootstrap-repository scope, preserved blank target and guest poweroff.
The first namespace-mapping failure remains preserved; selecting the existing
Joliet names with the documented mount option passed in a new fixture. Next run
explicit guest APK signature checks and dependency simulation with only the local
repository/keys and no network, scripts or package application. Compare live and
empty-target database scopes before any formatting/installation decision.

The guest's existing APK verifier (private development record omitted)
now passes all 49 archive signature/integrity checks, unchanged live database/world
and observed guest poweroff. Next dependency-simulation acceptance requires actual
tool exit/logs and chosen package identities for both the live database and a fresh
empty tmpfs target, with only the signed local index/keys and no network, scripts,
commits or package application. Preserve unsatisfied constraints as evidence; do
not silently adjust inherited requirements. The system disk stays unmounted and
blank throughout this prerequisite trial.

The dependency simulation (private development record omitted)
now selects the exact verified 49 packages for the empty target. The next slice
applies those packages into a new directory in temporary memory with scripts and
commit hooks disabled. Before execution, inspect authenticated archive headers
for bounded logical sizes and unsupported sparse/size overrides. Acceptance:
actual tool exit and complete bounded log, exact installed package identities and
six requested roots, only the matching 6.18.55 module namespace, pinned kernel,
and an inventory of helper files and raw link targets. Verify unchanged live
database/repositories, blank unmounted system disk and observed guest poweroff.
Missing helper links remain explicit prerequisites for a later generation step;
package application alone does not prove a bootable root. Keep chroot, helper
execution, initramfs generation and persistent installation as separate slices.

The authenticated payload bounds (private development record omitted)
now pass for the complete 49-package kit. The reviewed
temporary-memory application (private development record omitted)
also passes actual tool/log, 49 identities, six roots, kernel/configuration/module
inventory, unchanged live state/blank disk and normal guest shutdown.

Next acceptance: prepare only the missing BusyBox applet links and null device in
a new owned RAM root, preserve existing kmod aliases, and prove helpers/loaders
resolve within that root. Run depmod and mkinitfs through a true chroot with an
explicit 6.18.55-0-virt release, empty configuration and the inspected base/virtio/
ext4/scsi/usb feature set. Require actual exits and complete bounded diagnostics,
independent gzip/newc framing, init/tool/library closure, only matching modules,
vermagic and required driver dependencies or verified built-ins. Retain any
missing input despite a success-looking tool exit. Disk-root installation and
kernel/archive pairing for actual cold boot follow those checks.

The staged helper preparation (private development record omitted)
now passes true-chroot BusyBox installation into a fresh applet directory, null
device checks, actual shell/kmod/scanelf/lddtree probes, preservation and shutdown.
Before generation, inspect the exact 6.18.55 configuration body and feature texts:
USB ISO access also needs ISO9660/Joliet, and live modloop bootstrap needs
loop/squashfs. File presence and a proposed feature list do not establish those
driver dependencies or built-in settings.

The authenticated metadata collection now establishes the candidate feature union
`base virtio ext4 scsi usb cdrom squashfs`. The configuration declares console/HVC
and virtio PCI built in, while disk, ext4, SCSI, USB host/storage, ISO9660, loop
and squashfs need modular closure. Only base contributes absolute `.files`
inputs. Generation must resolve the actual 6.18.55 dependencies and independently
verify the resulting archive; declarations alone do not establish boot readiness.

Generation/export follows [ADR 15](docs/adr/0015-generated-initramfs-lab-export.md):
retain exact generated bytes through only the new owned lab disk, then check their
hash and complete gzip/newc contents independently after normal shutdown. Keep
export success, archive closure and actual boot as separate observations. No
registered VM disk or partition/filesystem operation belongs in this trial.

The generation/export trial (private development record omitted)
now passes actual depmod/mkinitfs, bounded retained bytes, independent gzip/newc
framing and declared init/tool/library/module closure. The separate
paired early-boot trial (private development record omitted) now passes
actual release/root/device observations, unchanged source/media/identity/blank
target and explicit sync followed by guest-kernel poweroff. Keep the old 6.18.52
pair and every earlier fixture intact. Actual early boot does not by itself
qualify ordinary service/filesystem shutdown, persistent root or guided installation.

The paired-image trial stops at the documented early `single` shell after
boot-media discovery. This isolates the generated 55 module tree from the stock
52 media's later APK/OpenRC/modloop reconstruction. Require actual 55 release,
RAM root, loaded storage drivers, read-only ISO and untouched unmounted target,
then observed sync and direct guest-kernel poweroff. This trial cannot qualify
ordinary live/OpenRC shutdown or persistent installation; the installed-root
boot and GUI workflow remain required.

The offline installed-root slice uses a new disposable 8 GiB target under
[ADR 16](docs/adr/0016-disposable-persistent-linux-root.md). Bind the
exact fresh target to its live VM owner before partitioning; preserve any failed
attempt. Probe actual filesystem tools, create GPT with a 256 MiB ESP and ext4
root, apply the exact signed package set, and explicitly stage init/services.
Require clean unmount and offline filesystem checks, then cold boot the qualified
55 pair from the target UUID with both ISO images detached. Acceptance requires
the actual disk root, persistent marker, offline networking and ordinary shutdown.
EFI bootloader installation and the guided GUI workflow need separate qualification.
The packaged startup-service inspection (private development record omitted)
now supplies exact inittab/service text pins and the fsck/root/localmount dependency
chain. The executed installation and two cold boots (private development record omitted)
now pass exact package application, init/service preparation, clean filesystem
checks, disc detachment, matching UUID roots, retained test data and ordinary
shutdown. EFI bootloader, graphical desktop and guided GUI acceptance remain.
Next product-facing work also includes the original native QEMU display surface
for the Windows path; media authentication and actual Windows installation remain
separate gates. Preserve the running packaged app while qualifying new builds.

## General keyboard transport checkpoint

The two-digit RFB restriction is replaced by bounded printable, Unicode, navigation,
function and modifier keysyms. Exact wire/release and host-state tests pass; the
AppKit observer implements capture, original-symbol key release and the permanent
release shortcut. Evidence and limitations (private development record omitted).
Next acceptance requires actual non-digit guest acknowledgements, followed by visible
capture/focus/shortcut behavior and real Windows layout tests. IME, left/right
modifiers and AltGr remain open; no feature was promoted to supported.

## First actual Windows installer boot

The maintainer-approved offline Microsoft ARM64 installer reached its English
language-selection screen under the native QEMU/HVF backend. Both owned runtime
processes then exited0, media was preserved, drains closed and the new disk remained
unwritten. Evidence (private development record omitted).
WIN-INSTALL is now experimental rather than wholly blocked. This does not close
Milestone0's compliant platform or any full install requirement. Next bring this
actual installer framebuffer into macOpenVM's native Liquid Glass window through
its retained-worker lifecycle, then verify input and the remaining platform gates.
Installation licence acceptance remains a separate human step.

## Native Windows installer display checkpoint

Actual native-window evidence (private development record omitted) now covers the approved offline installer, Liquid Glass presentation, synthesized Tab/Shift–Tab, display reconnect and app-quit survival under the retained Swift worker. All runtime children settled; media and blank disk preserved. This remains experimental. Next: pointer routing using the same rendered-viewport transform, followed by native geometry/fullscreen verification and the guided installation workflow. No installation, Retina, physical keyboard or full compatibility claim.

## Windows pointer checkpoint

Absolute pointer evidence (private development record omitted) covers a native-window click and capture release plus exact wire/bounds/close tests. Next acceptance: one usable cursor, scrolling and bounded motion handling; dynamic geometry and fullscreen remain open. Fresh offline test VM settled and media/disk preserved.

## Windows scroll checkpoint

Scroll/cursor evidence (private development record omitted) records passing bounded wheel/accumulator tests and exact native admission rejection. Native-window capture correctly refused background input. A separate native-client test verified actual Windows dropdown scrolling and Escape restoration, with explicit owner cleanup. AppKit/physical scroll and cursor acceptance remain open. The fixed-action CLI observer checks a reviewed full-frame hash before each setup-list input, captures the result for separate visual review, and never selects Next or accepts terms.

## Pointer motion checkpoint

Pending-motion batching (private development record omitted) now passes storm, button-edge, barrier, geometry and connection tests. Next acceptance: native-window motion and drag under load, release/focus recovery and measured latency; do not infer these from the earlier Windows wheel trial. Fullscreen menu/Dock behavior remains a separate open acceptance requirement.

## Fullscreen presentation checkpoint

Shared presentation policy (private development record omitted) now requests a hidden Dock and visible menus, restores only owned visibility flags, preserves native state and handles focus/display availability. Linux and RFB guest toolbars hide in fullscreen. Six app-module policy tests pass. Next acceptance is a current-build live guest window with edge checks, repeated entry/exit, focus/modal/sleep transitions and unchanged window/worker identity; no D5/D6 support claim yet.

## Ubuntu graphical live desktop

The official Ubuntu ARM64 desktop trial (private development record omitted) authenticates the complete ISO and boots its EFI loader and graphical live session through the existing native app. Persistent GUI installation, installed-disk cold boot and complete input/display acceptance remain open. The trial runtime is preserved while coordinating current GUI ownership with the user.

## Stopped hardware settings

[ADR 17](docs/adr/0017-stopped-hardware-settings.md) adds CPU/memory editing through
an experimental Liquid Glass sheet and the shared CLI. File/fault/admission tests,
actual signed CLI saves, native EFI configuration validation and two Linux boots
before/after a saved resource edit pass. Next acceptance: visually exercise
cancel, invalid values, save and re-open on a fresh stopped VM without disturbing
the live Ubuntu trial; qualify Windows guest resource application separately.
Windows settings metadata does not qualify the Windows runtime.

## Saved VM library

[ADR 18](docs/adr/0018-saved-vm-library.md) adds a bounded recent list, name/folder
search, Windows/Linux groups and open/hardware/remove-reference actions through a
Liquid Glass sheet. The sheet overlays the existing guest window and releases
input; selection waits for dismissal and remains disabled while a VM is busy.
Stored identities are checked on reopen and again at Start. Preference and actual
configuration tests pass. Next acceptance: app restart, search and context-menu
interaction, keyboard/VoiceOver, failed-location recovery and running/fullscreen
guest continuity on current and minimum macOS. User-generated thumbnails and wider
supported lifecycle/storage context actions remain to be implemented and verified.

## Authenticated firmware update correction

Native AUTH2 testing (private development record omitted)
reproduced equal-timestamp replay/replacement acceptance and verified a separate
correction with eleven cases. WIN-PLATFORM stays Experimental. Next acceptance:
valid signed image executes; unsigned/altered/revoked images are rejected without
execution; replay remains rejected across fresh guest boots and after
ExitBootServices. Requalify the corrected graphical candidate before adoption.
Full Windows/Linux GUI installation and all later product milestones remain.

## Native image enforcement and installation continuation

Nine original EFI image cases (private development record omitted)
now pass in a fresh boot, including selective dbx hash revocation with same-signer
positive controls. Persistent/runtime/Microsoft trust remains open. The maintainer
has authorized actual Windows installation in a fresh offline test VM. Acceptance
now prioritizes native Setup, its sole empty target, installation/reboot and the
first-run account handoff, followed by disk-detached boot and normal shutdown.
The production readiness gate stays unchanged until its full platform evidence
exists. Keep live installation ownership and preserve existing VM bundles.

## Stopped VM copies

Actual native Linux copy (private development record omitted) now creates
fresh VM/MAC/platform identity and independent writes, boots the installed guest,
records a new persistent write and normal shutdown while preserving every source
byte. Native copy dialogs now pass (private development record omitted).
Keep the path Experimental until EFI, guest identity/pairing, Windows
TPM/encryption, templates, older-host and fault/power-loss criteria pass.

## Reviewable support reports

Local structured report (private development record omitted) now exports
whitelisted status/capability facts through the app/CLI without raw guest or
identity data. Native save-panel save/cancel now pass (private development record omitted);
keep optional log
collection/redaction and complete support-bundle criteria open.

## Stopped networking settings

[ADR 21](docs/adr/0021-stopped-networking-settings.md) adds a separate Liquid Glass
editor and CLI for explicit disconnected/shared mode. Preserve registration
bytes, MAC, disk and platform state through a stopped-only exact-backup save.
Protected saves, CLI/device/controller checks and native sheet save/cancel now pass (private development record omitted).
Next acceptance: final native card/menu fixes and next-start device application.
Continue NAT inbound-exposure/reconnect,
Windows and minimum-host testing separately; metadata save is not connectivity.

## Authenticated guest health

[ADR 22](docs/adr/0022-guest-agent-tls.md) selects standard TLS 1.3 and generated
Swift/C messages over the public guest socket. Actual native Linux health and
unknown-host rejection now pass (private development record omitted),
with temporary identities and normal guest shutdown. This does not close Milestone 3.
Next acceptance: production pairing/Keychain custody and signing, persistent
least-privilege Linux service/session installer, Windows driver/transport and
service path, one-disc setup/health, heartbeat/reconnect, signed upgrade/rollback
and the remaining daily-use integrations. Keep all advanced feature requirements.

## Installed Linux service

Actual restricted Alpine/OpenRC installation (private development record omitted)
now passes four authenticated native connections across initial setup, reconnect,
disc-detached cold boot and service restart. Explicit credential-removing uninstall
prevents later admission while preserving unrelated accounts/files and the source
VM. The signed development package, private per-VM carrier and fixed test hook
are evaluation infrastructure; product GUI setup is still open.

Next acceptance: production enrollment/custody and signed setup delivery, upgrade
and rollback fault cases, other Linux systems and media reliability. Windows
remains primary: qualify the released ARM64 VirtIO serial candidate, then actual
guest driver loading, named-port I/O and authenticated health before service/session
adoption. The user approved licence acceptance and Windows reached first-run network setup. Preserve its live owner until the explicit shared-network and normal-resume choice is answered.

The original Windows ARM64 build-only smoke (private development record omitted)
now links native kernel/security/crypto imports without a CRT, with two identical
strict local builds. The released vioser candidate (private development record omitted)
passes offline signature/catalog checks. Next acceptance is actual ordinary Windows
execution, driver loading and bounded named-port I/O, followed by mutual TLS health;
neither static result closes the primary Windows installation or agent gates.

Owned retained-credential Linux reinstall now passes natively (private development record omitted),
including stable credentials/service identity, subsequent disc-detached cold boot,
restart and both uninstall refusal paths. Fresh re-enrollment after removal now
also passes on a third native boot (private development record omitted),
with the same reserved service account and new private TLS identity. Explicit
generation changes, old-peer rejection and recovery remain next installer gates;
preserve all existing account-conflict rules.

The next Linux source slice is a compatible-manager v2 generation transaction:
explicit upgrade, rollback and exact journal recovery, permanent kernel exclusion,
adjacent staging and verified service/supervisor quiescence. Acceptance requires
every rename and journal fault boundary, ambiguous-state refusal and unchanged
account/enrollment through A–B–A, followed by native distinct authenticated versions
and cold boot. V1 migration, manager self-update and production delivery remain
open; see [ADR23](docs/adr/0023-linux-agent-installation.md).
Distinct agent builds and same-issuer package verification now pass (private development record omitted).
The final transaction fault campaign and native generation qualification are
still pending.
Current source checks (private development record omitted)
now cover kernel exclusion, legacy refusal, quiescence and journal/rollback
replacement faults. Flush/prefix coverage and the actual three-boot trial remain.

The private same-VM Windows networking continuation now has an actual recorded
owner/lease entry point, with preserved prior opaque history and a fresh runtime
session on the existing disk/TPM/UEFI identity. Five pure policy/launcher checks
and four actual storage/owner contract tests pass; private compilation/signatures
pass. Continuation display consumers also compile and pass focused route checks (private development record omitted); actual route runtime and ordinary driver/OOBE networking
remain unqualified. The reviewed driver carrier and isolated QEMU/libslirp candidate
are prepared, but no network adapter or outbound guest networking has been enabled.
Normal shutdown/resume plus shared networking awaits the user's explicit choice.

Fresh Ubuntu creation through the native Liquid Glass assistant now succeeds (private development record omitted),
including ISO/destination pickers, offline EFI graphical boot and installer input.
The actual guest waits for human account/password entry; no persistent Ubuntu
installation or installed EFI restart is claimed. The older private executed App
is recorded precisely and does not qualify every subsequent current-source change.

The remaining QEMU normal-stop gap is the lifetime monitor reader: events are
currently discarded, so normal guest exits remain honestly classified as opaque.
Source work will retain same-connection guest shutdown provenance and settle it
with actual owned process/drain observations; an ACK, status or power button event
cannot establish guest stop. Both callback and durable receipt need one predicate,
including TPM/monitor/process delivery races. Current live owners stay on their
immutable executables. Actual Windows ACPI response remains a separate gate.

QEMU normal-stop source and local process/socket contracts now pass (private development record omitted):
one owned event reader, typed shutdown provenance, supervised request, shared
callback/receipt classification and worker opcode4/status/revision admission.
All82 focused functions and strict formatting pass. Actual guest poweroff/Windows
ACPI, UI exposure, sustained lifecycle/recovery and minimum-host remain unqualified.
The next real native proof uses a new original UEFI ShutdownProbe calling the
public firmware shutdown service on a fresh offline diskless fixture; it cannot
substitute for Windows ACPI acceptance. Existing live owners are unchanged.

Actual native diskless firmware poweroff now passes (private development record omitted):
same-connection guest shutdown/natural monitor EOF, both owned processes0/drained,
same-session guestStopped receipt, actual parent reap and writer release. Original
probe30s timer/public firmware shutdown; no host quit/force/signal. Windows ACPI,
installed OS shutdown/flush, UI request/recovery, repeated cycles and older hosts
remain distinct gates. Existing Windows and Ubuntu owners are unchanged.

Original Windows ARM64 metadata discovery/IOCTL diagnostic now builds twice identically (private development record omitted),
with exact native imports, ABI assertions, strict diagnostics and13 portable
bounds/completion contracts. Exact immutable interface/handler source is retained.
No PE/device/driver/elevation/guest action has occurred. Next actual binding and
cancellation trial requires the ordinary signed driver and explicitly configured
port; authenticated service/session and combined setup remain separate gates.


[Apple recorded backend and CLI boundary](docs/adr/0026-apple-recorded-ownership.md)
now builds under strict concurrency and passes 38 focused lifecycle tests. A fresh
Linux preparation plus first A→B installed boot commits actual guestStopped
history and matching settled intent after real SDK terminal callbacks, then releases
the real writer lease. Its overall runner remains failed due to a corrected public
support-label observation parser. Full three installed cold boots/rollback still
require a new run; historical failures remain unchanged. Desktop recorded routing
is the next source integration, preserving Liquid Glass and existing live owners.


The fresh recorded A–B–A trial (private development record omitted)
now passes: authenticated A/B/B/A/A health across three installed boots, same
restricted account/credentials, four genuine settled sessions including preparation,
normal SDK shutdown, full child drains and writer release. Earlier failures remain
retained. Compatible-manager upgrade/rollback is experimental evidence; actual
interrupted recovery/retirement, manager migration, product setup, desktop routing,
Windows and production credential gates remain.


[Ordinary desktop recorded ownership](docs/adr/0026-apple-recorded-ownership.md)
now binds before rendering, retains actual custody through delayed shutdown and
failed preparation/commit, releases it only after durable settlement, and captures
the intended runtime for queued controls. Four real-storage/lease helper tests and
existing App library/fullscreen/network tests pass. Current GUI/native close and
focus acceptance remain pending; existing live app/VM owners are preserved.


[Retained generation retirement](docs/adr/0027-linux-generation-retirement.md)
will archive exact failed generation and transaction evidence after completed
rollback, with shared kernel exclusion, normal service quiescence and explicit
resumable journal. Another compatible C upgrade must then pass without changing
account/credential identity. Manager-only bounds rise explicitly to128KiB; prior
signed manager/native proof artifacts are preserved. Retirement after a retained
upgrade and manager migration remain required later stages, not removed scope.


[Ordinary Windows creation/session integration](docs/adr/0028-windows-registered-runtime.md)
now has the shared platform file/private-directory durability seam, with33 focused
source registrations passing. Next implement reviewed QEMU platform resources and
normal selected-ID worker/display attachment; empty TPM state is not guest health.
Existing Windows test installation remains at first-run network setup, with consent
and installed-driver/cold-boot/shutdown checks still open.


### Current-manager native retirement and cold-A acceptance

Actual retry 60577 exited successfully after three installed boots on a fresh private Alpine/OpenRC VM. Five host-authenticated TLS 1.3 health replies confirmed versions A/B/B/A/A (0.1.0/0.1.1/0.1.1/0.1.0/0.1.0). Boot two retired B after rollback health, stopped its service normally and preserved A, account/enrollment data, the permanent kernel lock, B program/state and the generation cohort. Boot three authenticated cold A and rechecked the archive, exact completed retirement record and confirmation, including their bytes and inodes.

All four recorded owners, including preparation, completed normal guest shutdown with their actual child exit, EOF, drains, closed pipes/transcripts, settled intent and available kernel writer lease. Root independently checked the final session 7AD3E103-8333-46F3-ACCB-C7E6B0FFCD02, guestStopped history, settled intent and an exclusive writer lease after actual parent termination. The original source disk remains unchanged. The successful trial's transient host credentials and private support carrier were removed after these checks; the failed earlier trial and its credentials remain protected separately.

Evidence: .lab native result (private development record omitted), SHA256 `86f8aaa16cc97db3ed12305b75c6c45f002a7dd016d3b8b401944293d4baf74d`; independent final-owner review (private development record omitted). VM D99D5D66-1796-4CE9-AF7B-BEA3C9904918 is stopped at `/private/tmp/agent-guest-73ff2905e488433fade262ce912def98/Agent.macopenvm`.

This is experimental acceptance for manager60c, the reviewed A/B packages, Linux6.18.55, OpenRC0.63.2 and the named native host/backend fixture. The harness validates each actual health reply before recording its version; full raw TLS reply JSON is not retained. The recovery request was unnecessary in the successful run and has source/controlled-fixture qualification only. Native interruption recovery, power loss, C upgrade, manager migration, production signing/pairing and daily-use features remain open. The failed first trial is not promoted by this retry.


Ordinary Windows follow-up: normal CLI creation and validation evidence (private development record omitted) now verifies the reviewed QEMU file-only transaction on a new blank offline VM. Registered worker/store/context sources compile and focused tests pass. Next qualify actual registered startup, display detach/reconnect and explicit terminal settlement, then activate the Liquid Glass Windows creation and library-start paths after their own tests. The separate installed Windows E725 session is at the human sign-in handoff. No Windows account, desktop, full compatibility or GUI-start acceptance is claimed.

The registered driver carrier (private development record omitted) now passes actual stopped selection/refusal and offline startup/reconnect/explicit forced settlement. The first ordinary App qualification failed before ownership because Foundation aliases an existing `/private/tmp` URL to `/tmp`, causing the library's canonical-URL equality gate to reject the original path. Fix lexical local-path admission and preserve the selected path, prove it with an existing-file regression, then repeat the App test on the verified unused fixture. No GUI usability, driver health, networking or clean Windows shutdown acceptance follows from these narrow trials.


The fresh registered Windows worker slice (private development record omitted) now passes offline startup, read-only display reconnect and explicit forced settlement. Next wire the signed bundled helper admission, actual retained App parent and injected registered renderer into library Start. Visible GUI, guided installation and clean Windows shutdown remain acceptance gates; the two earlier failures are preserved separately.


[Registered Windows NAT runtime](docs/adr/0029-registered-windows-nat-runtime.md) is the next independent source slice while the real App-window test awaits the account-input handoff. The runtime executable/capability must come from an independently reviewed catalog, while existing creation provenance, VM/MAC identity and disk/EFI/TPM bytes remain unchanged. Source acceptance requires exact offline/shared device arguments, selected-runtime signature/import/hash checks and file-only state preservation. The authorized registered installation and disc-free cold boot have now passed narrowly. Experimental shared controls are implemented under ADR32; corrected ordinary App sheet/save/Start/SDK drawing/normal-stop/quit acceptance now passes; physical GUI and detailed driver/network health are next. Existing A5C networking evidence stays narrowly scoped.

The path fix and18 focused checks now pass. A new isolated App trial passed ordinary programmatic Windows selection/start, native renderer attachment/drawing and explicit forced settlement with actual child drains, settled records and App reaping. See App evidence (private development record omitted). Next complete real menu/picker/input and installed guest acceptance; SDK metadata does not substitute for those workflows.

The normal registered Windows installation/network trial (private development record omitted) now reaches installed OOBE and UI-reported Connected, with actual normal guest shutdown and full owner/child/drain/flush/intent/lease evidence. Both discs were detached while stopped. Installed-disc-free cold boot and a second normal stop now pass on the same VM. The corrected ordinary App shared-network sheet/save/Start/SDK drawing/normal-stop/quit path now passes. Next verify physical GUI, exact driver/network health and GUI/account/desktop use; no full Windows support or parity claim follows.


## Per-VM credential custody — 2026-10-10

Experimental source slice: bounded add-if-absent Data Protection Keychain store,
redacted private records and explicit store-backed TLS/health calls. Eleven
injected store/integration registrations plus four existing local TLS guards pass;
no native Keychain or VM calls occurred. See [ADR34](docs/adr/0034-per-vm-keychain-credentials.md)
and evidence (private development record omitted).

Next acceptance: a qualified signing/access-group context and isolated no-UI
native probe; explicit identity issuance/enrollment with private custody; actual
store-backed guest health and denial/reconnect checks. Missing pairing must leave
unrelated VM boot usable. Native persistence and Windows service/session transport
remain open; source tests do not qualify the production workflow.

Windows transport next slice: [ADR36](docs/adr/0036-registered-windows-agent-channel.md) defines an explicit default-absent registered virtio-serial evaluation channel. Acceptance requires unchanged ordinary launches, endpoint/publication tests and a fresh native signed-driver/named-port/fragmented-I/O trial before TLS health or combined installer claims.

Recoverable stopped-VM relocation [ADR37](docs/adr/0037-stopped-vm-trash.md) now has narrow native CLI results for plain and deny-protected source parents. Next acceptance: real same-window confirmation/cancel, Finder recovery, actual Documents consent, alternative folder names/external volumes, older-host and interrupted relocation tests before promoting stable deletion support.

Windows authenticated integration requires the [credential-hosting gate](docs/adr/0038-windows-tls-credential-hosting.md): actual TLS1.3 certificate signing under scoped native Schannel credentials before vioser service/Hello/Health integration. Import or acquisition alone is not acceptance, and no silent key-persistence or trust fallback is allowed.

The Schannel token contract (private development record omitted)
now passes fifteen strict and sanitized portable cases and independent review.
The original native ARM64 in-process credential evaluator now builds twice identically (private development record omitted).
Next record actual TLS1.3 signing/context/scoped-peer checks and cleanup or a native
refusal, then implement and qualify encrypted records and transport. Portable
fixtures and static PE builds cannot qualify native signing or health.

Fixed-record custody checks (private development record omitted)
pass fifteen strict/sanitized portable cases. Native record integration remains
after actual credential signing/scoped-peer acceptance; no encrypted record or
post-handshake execution is inferred from the fixtures.

The native fixed-record adapter now builds twice identically (private development record omitted)
with 36 exact imports. Eleven additional tests execute its actual observation
functions using descriptor fixtures. Next qualify actual Windows signing, scoped
peers and both encrypted records; then rehandshake, transport and generated health.

Library settings next slice: expose the existing Liquid Glass networking editor
from a saved VM's context menu and accessibility action. Acceptance requires
same-window dismissal and exact VM identity, idle/stale/modal/owner-change refusal,
no stuck pending request or late replay, focused tests and strict build. Actual
physical menu/sheet interaction remains a separate GUI gate.

The library networking shortcut (private development record omitted)
now passes ten network-session and twenty-two library/Trash regressions with
strict lint, independent review and an isolated development build. Next qualify the
actual native menu and same-window sheet workflow without disturbing live guests.

The same-window native library→network sheet→controller cancel path now passes on
an unused no-OS fixture, with actual app exit and file preservation. Physical
menu/button/VoiceOver and Windows/older-host scenarios remain acceptance gates.

Creation storage capacity (private development record omitted)
now passes focused storage/creation/observer checks and strict lint. Acceptance
also includes an isolated signed build and actual read-only CLI observation;
physical assistant picker/refresh and installation/disk-full scenarios remain.

Display responsiveness next slice follows [ADR40](docs/adr/0040-rfb-raw-decoding-measurement.md):
capture an unchanged release decoder baseline on generated public frames, test a
bounded row-decoding candidate if justified, then compare identical workloads
with exact pixel/snapshot/coverage regressions. Native frame pacing remains a
separate acceptance gate.

The row decoder candidate (private development record omitted) now passes
23 decoder/client tests, six sanitized parser tests and an identical-workload
release comparison with all pixels checked. Next qualify native transport/render
frame pacing and input latency; these component timings do not close that gate.

[ADR41](docs/adr/0041-generated-native-display-path.md) defines the next native
client/renderer qualification using generated public frames on a private Unix
fixture. Acceptance requires actual natural SDK draws and close/exit settlement;
physical scanout and real-guest input/graphics remain separate gates.


## User-reported capture and top controls — 13 October 2026

Capture and toolbar evidence (private development record omitted) records
a persistent capture preference with held-input release, stale-queue invalidation
and same-foreground-owner recapture, plus always-visible native VM controls.
Focused tests and an actual optimized Windows handoff pass narrowly. Acceptance
remaining: repeated physical app switching, fullscreen/menu/Dock/owner transitions,
explicit release, modal focus and older-host checks. Native Windows backing-pixel
mode application and measured frame pacing require a qualified driver/device path.


ARM64 display-only candidate (private development record omitted)
now passes pinned package/member/PE/offline signature inspection. Next acceptance:
matching virtio-gpu PCI1050, retained firmware fallback, normal Windows driver
loading on a preserved copy, actual guest-applied modes and authoritative pointer
geometry, followed by frame intervals and latency. Live signed-in RAMFB remains
unchanged; no native Retina/FPS or accelerated Windows claim.


[ADR42](docs/adr/0042-windows-native-display-evaluation.md) now tracks the user's
Windows native-resolution/FPS and capture work as executable acceptance gates.
Real GPU PCI1050/mode properties and clean diskless exits pass. Active-cadence
candidate builds and probes pass; Windows loading/applied modes/frame pacing,
viewport changes, input and soak remain required. Continue on a preserved copy.


### Menu-only VM controls and current native-resolution qualification

The latest user request supersedes the permanent VM toolbar. The v15 release
shows Machine/View/Input controls in the actual macOS menu bar, no app toolbar,
and defaults Windows to guest-cursor mode. UK quotes/backslashes work in a
native synthesized-input check. Bounded first-key capture and49 focused checks
pass. Evidence and limits (private development record omitted).

Next acceptance: deploy the windowed safe-area polish, verify one usable Windows
cursor and host restoration at menus/focus/release, and physically test app-switch
first input. Qualify the measured-viewport menu request against a newer exact
framebuffer and guest mode, without assuming transport success means resolution.
The v4 original ARM64 diagnostic adds read-only raw-mode enumeration and matched
CCD target timing. Preserve signed drivers and signature enforcement. The current
signed driver rejects exact3456 mode with1610; a standard PnP restart succeeded for
the connected GPU but desktop updates then stopped. Normal guest shutdown later
completed; the failure's cause is not proven. Driver recovery and native delivered
frame pacing remain open; no parity or stable GPU claim follows from30.5 shaderFPS.

### Current Windows graphics acceptance, 15 October

The experimental path now has actual native3456×2168 CS2 delivery and a
physically confirmed relative game mouse; see ADR48–50 and the15 October evidence.
Keep120 fresh frames/s and long-term stability open. App67/68 startup and game
transitions retain Metal without manual reconnect. The exact ACK-race injection
remains unverified; a passing transport regression alone does not prove that live
boundary. ADR51's identifier optimization renders correctly in actual Windows,
but its menu/gameplay results are mixed and establish no overall FPS gain.

Frame-production and graphics-memory work must compare matching Windows scenes
with exclusive host test windows, record both rates and long gaps, and distinguish
host aggregate paging from VM attribution. The24/16GiB sequential comparison was
inconclusive, so24GiB/12vCPU was restored. Any120Hz qualification must verify an
actually applied guest target mode, fresh frame delivery and host presentation
separately; a faster counter or changed EDID alone is insufficient.
At that earlier checkpoint, the installed signed Windows driver exposed60Hz. The public source's target
timing builder and active-refresh accessor fix that rate;120Hz needs a compatible
signed driver mode/timing path as well as host frame-pacing work. No signature
enforcement change is part of this workstream.

### Windows sound and renderer object lifetime

[ADR52](docs/adr/0052-windows-audio-playback.md) adds a fixed caller-reviewed,
playback-only HDA/CoreAudio recipe. QEMU34 had no CoreAudio backend. App69 loads
the Windows inbox driver/endpoint; App71/QEMU38 starts its own CoreAudio callback
and delivers finite, unclipped float32 stereo. The user still reports missing or
distorted sound, so channel/routing, endpoint and listening quality checks remain
required. Native output properties are unmuted at48kHz; a separate generated
AudioQueue output comparison passes its API lifecycle, with listening pending. The original
callback drops partial buffers; the corrected actual-callback probe passes ring
wrap, silence, output bounds and lock/device-failure cases. Microphone forwarding
remains a separate consent/revocation feature.

[ADR53](docs/adr/0053-renderer-completion-object-lifetime.md) adds a per-chunk
autorelease pool for the long-lived native completion thread. Preserve GPU
completion and resource-retirement ordering, verify the native ABI/imports and
qualify in Windows before admitting its replacement library. The native ABI,
signing, actual Windows startup and CS2 menu checks pass in App69/70. The existing
large renderer footprint does not establish a leak, and no memory/FPS gain is
claimed. App70 still records429–475ms drawable acquisition waits outside any
controlled benchmark; classify foreground/gameplay versus window transitions
before attributing the remaining freezes.

The user requested a game-capture exit keybind. Control–Option–Escape passes the
live App70/71 release checks. App71 makes Release Game Mouse explicit in the Input
menu and recognizes physical Escape independently of its character string.
Capture-policy regressions cover pointer reassociation and no release key
delivered to Windows. [ADR54](docs/adr/0054-hidden-window-drawable-acquisition.md)
passes native/4K hidden cache-copy validation plus live startup, native fullscreen
and focus recovery. A controlled native CS2 sample and120Hz qualification remain
pending; no FPS improvement is inferred from the visibility checks.

[ADR55](docs/adr/0055-pipeline-task-object-lifetime.md) extends temporary-object
lifetime coverage to pipeline compilation workers. The native old/new adapter
probe, renderer build, signature and16-name ABI checks pass; installation and
Windows memory/frame results remain pending. [ADR56](docs/adr/0056-windows-high-refresh-driver-trial.md)
reviews today's official v0.4 driver: host EDID/DisplayID refresh timing and a
high-resolution display timer replace the installed v0.3 fixed60Hz path. Publisher
digest, Microsoft catalog/PE binding and CRL checks pass. A separate typed120Hz
host trial is prepared, defaulting all existing launches to60Hz. Applied Windows
timing, internal CS2 resolution, fresh frame delivery and physical scanout still
require live proof; no120Hz support or FPS result is inferred from source review.

16October: App73's corrected CLI option gate boots Windows natively, but v0.4
fails live at60Hz. Firmware-only recovery verifies the exact signed package and
restored recovery settings; rollback restores the3456×2168 desktop. All actual
VM/app parents are settled and closed. [ADR57](docs/adr/0057-graphics-protocol-pairing.md)
identifies guest protocol2 against host1 and prepares an isolated matching host,
Metal backend and common ABI. Keep the working runtime available, qualify the
pair before another package adoption, then resume native120Hz/CS2 acceptance.

The matching App74 pair subsequently passes actual ABI1/capset2 admission and
191 native D3D11 cases, then boots the signed v0.4 driver to a 3456 × 2168 Windows
desktop at 60 Hz. Device health, active SYS hash and hardware D3D11 creation
match the trial. First GPU arrival reapplies the INF's recovery overrides;
the live diagnostic catches them and the reviewed restoration removes both
before normal shutdown. The separately owned 120 Hz trial reaches a 1280 × 1024
lock screen. Post-reboot defaults, applied timing, native mode selection and
CS2 frame delivery remain open while macOS is locked. This is not a 120 FPS
qualification; preserve the previous runtime and rollback packages.

The subsequent App74 readback verifies the matched v0.4 pair at3456 ×2168 and
120/1 source/CCD target/path timing, healthy hardware D3D11 FL11.1, recovery
defaults after reboot and matching CS2 settings. Native120Hz mode application
is now verified narrowly; sustained120FPS, mode persistence, game pacing and
physical scanout remain open. The prior app and VM then settle normally and
the actual app parent exits/reaps0. Resume with App75's separate presentation
measurements and a changing scene, preserving App74 and all VM/rollback state.


Windows presentation follow-up (16 October): App78 now reports positive Mac
presentation timestamps at native 3456 × 2168 fullscreen: 105.8/s over 20 seconds,
worst gap 16.67 ms. App79 excludes fullscreen windows on another Space, including
stale key/active/visible flags, and replays cached presentation on Space changes.
Its focused tests/release pass. After manual unlock, App79 verifies Space/focus
guards, fullscreen resume and a browser-chrome reconnect sample106.0/s. The
full-display shader delivers107.1 Mac presentations/s at the native viewport,
worst gap16.67ms; the shader buffer is3456×2169 because ofDPR3 CSS rounding.
The VM and actual app parent close/reap normally0 with settled intent. Continue
producer readback/render scheduling attribution, full-display active-Space
reconnect repetition and a controlled game scene before changing the frozen pair.
120 FPS and long-running stability remain open. Track durable volume identity
for completed disk-growth records after host remount separately; the one-time
validated mount reconciliation is recorded with the original journal preserved.
