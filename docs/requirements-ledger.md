# Requirements ledger

Full objective remains open. This grouped ledger maps every original requirement
family; detailed capability rows are in FEATURE_MATRIX and procedure IDs below.
Verified narrow behaviors are linked in FEATURE_MATRIX and
native evidence (private development record omitted); family completion is not
inferred from those slices.

| Source family | Contract / decision / evidence | Remaining work |
|---|---|---|
| Variables/branding/clean room/license 1–8 | PRODUCT_SPEC; NOTICE; ADR 5; legal risk register; dependencies.json | Controlled release ID, complete redistribution/patent/legal review |
| Product principles/reality constraints | PRODUCT_SPEC; capability map; threat model | Safe defaults, truthful capability UI, no telemetry, graphics/peripheral verification |
| Repository modularity/planning artifacts | architecture; ROADMAP; this ledger | Populate modules only as behavior is implemented; keep evidence updated |
| Architecture 1: core/device/lifecycle/error/persistence | data-formats; ADR 1; Core/BackendAPI; CoreTests; history (private development record omitted); pair (private development record omitted); lease (private development record omitted); monitor (private development record omitted); intent (private development record omitted); Core (private development record omitted); settlement (private development record omitted); client loss (private development record omitted); pair loss (private development record omitted); single survivors (private development record omitted); native stop ordering (private development record omitted); [ADR9](adr/0009-qemu-crash-ownership.md) | Narrow state/history/monitor/intent/settlement, client loss, pair and lab single-survivor lease/admission, and Apple/Core contract ordering verified; recovered observations/receipt/settlement, production fault policy, Fresh Apple CLI recorded native shutdown/cold boots (private development record omitted) pass narrowly; broader reference/recovery qualification, desktop/backend adoption, fault IPC, filesystem recovery and full contracts remain |
| Architecture 2: verified native backends | capability map; ADR 1; host audit; native evidence; initial HVF EFI/TCG2 probe (private development record omitted); NV restart and completed-write process crash (private development record omitted); positive public-test trust chain and own signed EFI image (private development record omitted); eleven authenticated KEK replacement cases and equal-timestamp correction (private development record omitted); signed/unsigned/altered image loading and selective DBX hash revocation (private development record omitted); no-OS framebuffer/USB prerequisite (private development record omitted) | Actual Windows installer boot to language selection (private development record omitted) now observed under HVF, alongside narrow EFI/NV/trust/RAMFB tests. Full Windows installation, Microsoft trust/security enforcement, TPM identity/PCR/power loss, complete display/input, actual Windows and older-host fallbacks remain |
| Architecture 3: protocol/agents/security/integrations | guest-agent-protocol; threat model; installed Linux service (private development record omitted) | Generated TLS health and restricted Alpine/OpenRC install/cold boot/reconnect/restart/uninstall and fresh re-enrollment (private development record omitted) now pass narrowly. Compatible-manager recorded Alpine/OpenRC A–B–A cold boots (private development record omitted) now pass. Current-manager A–B–A retirement and authenticated cold A also pass on the exact native fixture. Production pairing, Windows service/driver/session route, native interrupted recovery, C upgrade, manager migration and daily-use integrations remain |
| Persistent Linux installation prerequisites | paired boot selection (private development record omitted); private package inputs (private development record omitted); serial ownership (private development record omitted); actual guest verification (private development record omitted); dependency simulation (private development record omitted); temporary-memory application (private development record omitted); staged helpers (private development record omitted); generated archive (private development record omitted); actual paired early boot (private development record omitted) | Actual offline disk installation and two cold boots (private development record omitted) now pass service startup, filesystem checks, disc removal, UUID mounts, retained test data and ordinary shutdown. EFI, graphical desktop, GUI installation, power-loss recovery and other hosts remain |
| Architecture 4: storage/snapshot integrity | ADR 3; data-formats; VMFiles; StorageTests; sector/crash (private development record omitted); lease (private development record omitted); intent (private development record omitted); Core (private development record omitted); settlement (private development record omitted); client loss (private development record omitted); pair loss (private development record omitted); single survivors/actual admission (private development record omitted) | Pair and lab individual survivors retain the same lease after worker loss; public cleanup later frees it while actual unsettled intent still rejects admission with inventory unchanged. No recovered survivor terminal/drain/settlement proof; production runtime recovery, delayed drains, hostile races, real disk-full/filesystem/power loss, clone and snapshots remain. Offline grow-only capacity and explicit completion (private development record omitted) now pass shared Windows/Linux CLI, actual file/fault/lease/archive and read-only doctor tests; guest partition expansion, visible settings and minimum-host qualification remain |
| Architecture 5: networking | ADR 4; native offline and shared-network/serial evidence | No-NIC and narrow real MAC/DHCP/route/DNS/verified-HTTPS tests pass; inbound, reconnect, performance, forwarding, host-only/bridged remain |
| Architecture 6: native desktop/CLI | PRODUCT_SPEC UX; verification D1–D7; native GUI creation and focus evidence | Shared Linux creation/live boot and input capture verified narrowly; library, persistent install/settings/logs and complete accessible input/display remain |
| Maintainer addition: Liquid Glass | PRODUCT_SPEC; UI-GLASS in FEATURE_MATRIX; actual host appearance and lifecycle evidence (private development record omitted) | Native macOS 26+ controls/status/navigation and narrow light/dark/input/close/quit checks passed; full VoiceOver, preference, layout, performance and older-host audits remain |
| Architecture 7: seamless windows | ADR 2, seven gated stages | All enumeration/compositor/input/UAC/recovery/policy/soak stages |
| Architecture 8: graphics/compute | ADR 2; PERFORMANCE; actual no-OS RAMFB capture (private development record omitted); [planned native client ADR 10](adr/0010-native-qemu-display-client.md) | Basic synthetic framebuffer and headless native client/keyboard/reconnect (private development record omitted) prerequisites passed. Actual Windows installer window, narrow synthesized keys, reconnect and app-quit survival (private development record omitted) passed. Windows driver, Retina, renderer/Metal path, API correctness, copies/sync/shaders/cache/containment remain |
| Architecture 9: peripherals/sharing | FEATURE_MATRIX; threat model | Pointer/keyboard/audio/camera/USB/print/folders/clipboard consent/device/recovery matrix |
| Architecture 10: privacy/security/updates | SECURITY; threat model; protocol; bounded metadata corpus (private development record omitted) | Metadata mutation/redacted-error and stop-record tests pass narrowly; coverage-guided/protocol/import/export fuzzing, Keychain/isolation/updates and security reviews remain |
| Parity matrix/interactive graphics/performance | FEATURE_MATRIX; PERFORMANCE; benchmark schema; bounded host-process comparison (private development record omitted) | Host-only n=3 CPU samples recorded with uncontrolled load; requested guest/desktop/Windows metrics, confidence/regression acceptance and honest renderer identity remain |
| Test layers/fault injection/skip policy | verification; scripts/check; CONTRIBUTING | Real contracts/guests/UI/property/fuzz/fault/device/soak/regression campaigns |
| Preserve existing installations/one app/reproducibility | Empty-workspace audit; ADR 5; data-formats | Future tested identity-preserving migrations; tracked dependency source builds |
| Desktop acceptance 1: native geometry | verification D1 | Live viewport/backing scale, guest mode and input alignment |
| Desktop acceptance 2: end-to-end resize | verification D2; separate GOP mode/readback/capture prerequisite (private development record omitted) | Real OS host-geometry/driver/applied framebuffer/input alignment with version/ack/coalesce/retry/stale/reconnect/sleep/monitor path |
| Desktop acceptance 3: pointer | verification D3 | One cursor, authoritative transform, release/capture/device matrix |
| Desktop acceptance 4: keyboard | verification D4; narrow no-OS USB repeated-key target proof (private development record omitted); general translation/wire/release checks (private development record omitted) | Actual Windows and complete physical/synthetic/layout/repeat/modifier/IME/focus/release proof |
| Desktop acceptance 5: fullscreen | verification D5 | Native menu bar, uncropped guest, no overlays, scoped Dock restore |
| Desktop acceptance 6: window lifetime | verification D6 | Exactly one owner, native transitions, detach/dialog/sleep/recovery |
| Desktop acceptance 7: library/menus | verification D7 | Auto hide/deliberate reopen/context actions/confirmed delete |
| Desktop acceptance 8: one support disc | verification D8; separate read-only support image (private development record omitted); ADR14 | Fresh Linux passive delivery/54 hashes/guest poweroff passed; one lawful combined Windows agent/driver setup entry point and actual Windows device loading remain |
| Desktop acceptance 9: reliable setup | verification D9 | Real Windows launch/elevation/progress/errors and verified component health |
| Desktop acceptance 10: credentials | verification D10; experimental per-VM store (private development record omitted); ADR34 | Injected missing/interaction/denied, duplicate, bounds, redaction and pre-channel checks plus an actual isolated no-UI missing-item read pass; native signed custody, locked/denied behavior, enrollment and actual stored-identity guest exchange remain |
| Sustained behavior/workflow/coding/CI/release | ROADMAP; CHECKPOINT; CONTRIBUTING; release instructions | Strict Swift/concurrency/cancellation/logging/format; CI and stable/full parity gates |

`supported` always names exact verified behavior. The first stable release and
advanced feature completion are separate gates. No commit/publication authorized.

Windows display/input follow-up: native window (private development record omitted) and narrow absolute pointer slice (private development record omitted) now have actual guest evidence. This does not close D1–D6 or guided installation.

Pointer follow-up: scroll and cursor evidence (private development record omitted) records bounded wheel transport tests, actual Windows list scrolling and Escape restoration, an explicit default-off cursor option, native admission rejection and the remaining foreground/physical-input acceptance. D3 remains open.

Pointer load follow-up: pending-motion evidence (private development record omitted) qualifies bounded batching with immutable click/release coordinates and ordering barriers. Actual native-window stress and latency acceptance remain open.

Fullscreen follow-up: scoped presentation implementation and tests (private development record omitted) replace the RFB auto-hide request and Linux whole-snapshot restoration. Native current-build screen-edge, menu, window-transition and macOS 14 acceptance still must satisfy D5/D6.

Linux graphical follow-up: authenticated Ubuntu media and native live desktop (private development record omitted) now have direct GUI evidence, alongside one pointer action and typed application search. Persistent graphical installation, shutdown of this run and full desktop acceptance remain separate.

Hardware settings follow-up: the protected CPU/memory editor and CLI (private development record omitted) now implement next-start changes with exact backups, guest/host validation, stale-editor rejection and active/pending writer exclusion. Real CLI, native configuration and two Linux boots observing changed resources pass; visual sheet interaction and Windows guest resource application remain open.

Library follow-up: saved-VM references (private development record omitted)
now implement bounded app preferences, search, Windows/Linux groups, deliberate
menu reopening and open/settings/remove-reference actions. Current configuration
identity is checked on reopen and Start. Windows metadata can be selected without
enabling its unqualified runtime. Actual preferences/files/session tests pass;
native library interaction, relaunch, live-window/fullscreen continuity, thumbnails
and the remaining D7 actions still need acceptance.


Apple ownership follow-up: [backend, CLI and desktop recorded routing](adr/0026-apple-recorded-ownership.md)
now retain exact native callback/real writer custody and settle same-session history
and intent. Actual compatible-agent A–B–A CLI cold boots pass; desktop source tests
include preparation/commit failures and cancellation. Current graphical lifecycle,
close/focus/fullscreen and minimum-host qualification remain open.


Windows library follow-up: [ADR28](adr/0028-windows-registered-runtime.md) defines
normal creation, selected-ID recorded worker and injected Liquid Glass display
routing. Shared creation/private-directory durability now passes33 source tests.
Reviewed QEMU platform/resource and registered worker/store/display-context source tests now pass. Actual normal Windows CLI creation/validation (private development record omitted) passed without launching a guest. The native registered worker and actual Windows GUI runtime stages remain incomplete.


Windows installation follow-up: the approved fresh Windows11 Pro test installation
accepted its displayed licence and self-restarted into first-run network setup.
Prepared continuation (private development record omitted)
remains separate from actual networking/driver/loading, account handoff, desktop
use, disc-detached cold boot and normal Windows shutdown. The existing offline
owner is preserved; historical boot-only reports keep their original scope.


Ordinary Windows networking follow-up: [ADR29](adr/0029-registered-windows-nat-runtime.md) separates immutable creation provenance from an independently reviewed NAT runtime executable. Existing A5C connectivity evidence does not qualify new registered trials. The human’s Windows installation, VM-control and NAT approvals plus continued goal instruction authorize equivalent disposable project trials; this is an authorization audit, not a fabricated new reply. Fixed NAT/MAC and resource checks are under source implementation; public GUI shared mode, driver carrier, real network diagnostics and normal/cold-boot acceptance remain open.

The registered runtime selector passed57 focused checks and actual read-only resource verification. Stopped normal CLI driver-disc selection (private development record omitted) passed attach/validate/detach/validate, byte/identity preservation and unreviewed-image refusal on fresh VMs. Native support-drive boot, driver health, public shared mode and networking acceptance remain experimental and unverified.

The same carrier evidence (private development record omitted) now includes actual offline registered startup, display reconnect and explicitly forced settlement with full child/drain/intent/lease evidence. This remains experimental: it establishes neither driver loading nor networking nor normal Windows shutdown.

Ordinary App startup (private development record omitted) now passes programmatic selection/start, current-generation SDK renderer attachment/drawing and explicit forced-settlement/App-reap checks. The existing-file Foundation path-alias defect was fixed with18 focused tests. Physical UI/input, creation/install, native geometry, clean Windows shutdown and daily-use acceptance remain open; status stays experimental.

Stopped Windows installation preparation (private development record omitted) now passes90 focused Swift checks, actual ordinary App driver-disc selection/offline startup/forced settlement and normal CLI shared/no-op/disconnect byte/identity preservation. Windows driver execution/health and fresh registered NAT/normal-shutdown/cold-boot acceptance remain open. The later installation and cold-boot trials now pass narrowly; experimental Windows shared Liquid Glass controls are implemented under ADR32, with ordinary App native acceptance pending. No support status is promoted.

The actual registered NAT attempt exposed an unreviewed default NIC-ROM dependency
and empty failed-start TPM settlement mismatch. The NIC correction (private development record omitted)
passed13 source tests; the trusted failed-start distinction (private development record omitted)
passed19 owned-process/file/receipt tests. The separate fresh native retry subsequently installed Windows to OOBE and passed normal shutdown and disc-free cold boot. Failed9087 ownership is preserved; explicit precommit/uncertain-commit
recovery remains open and cannot be inferred from inactive status alone.

Registered Windows installation/network (private development record omitted)
now reaches installed OOBE through the normal worker, accepts the reviewed disc via
the standard driver picker, displays Connected and passes actual normal shutdown
with exits/drains/flush/settled intent/EX. Same-VM disc-free installed cold boot and a second normal shutdown now pass. Desktop/account, physical GUI/input and precise driver/DHCP/DNS/TLS health remain open. Status stays
experimental; installation-to-OOBE does not satisfy the full GUI/daily-use goal.

[Windows shared Liquid Glass settings](adr/0032-windows-shared-liquid-glass-settings.md) now pass20 focused source registrations, including exact-baseline eligibility and stale/invalid-profile rejection. Ordinary App native sheet/save/Start and normal shutdown are the next acceptance slice; source tests alone do not qualify that workflow.

Corrected ordinary App Windows shared workflow (private development record omitted) now passes real sheet permission/no-op Save, installed Start, SDK drawing, explicit normal Stop, full actual settlement and Quit/App exit0. An old-settled-intent startup race was fixed with two regression tests and28 focused App checks; the first App failure remains separate. Physical GUI/input, post-boot network/driver health, account/desktop and full goal remain open.

Existing Windows worker CLI controls (private development record omitted) implement explicit status/pause/resume/stop/force-stop routing without new owners or PID adoption. Six local IPC registrations/nine cases and actual signed CLI option refusals/live status pass with preserved metadata. Lifecycle ACKs do not establish shutdown; native mutation, other backends and full CLI acceptance remain open. The A80 recovery was later explicitly approved and completed; forced recovery and new running session (private development record omitted) are recorded separately.

Native ordinary CLI lifecycle contract (private development record omitted) now passes actual running/paused/resumed states, paused-stop and missing-force-confirmation refusal, explicit forced cleanup, owned worker/child exits, drains, durable forced outcome and released writer on a new original offline no-OS fixture. Windows normal shutdown, desktop use, other backend routes and full CLI remain open; the current installed A80 setup VM was untouched.

Bounded registered test-display navigation (private development record omitted) now has exact-session native click/key and asynchronous recovery-to-region/keyboard evidence, plus real pinned-output/ACL tests and a verified development build. Full GUI input, long-running display reliability (actual rfb.limitExceeded retained), account/desktop completion, Windows agent and Retina/performance remain open. No supported status was promoted.

[Registered Windows agent-channel ADR36](adr/0036-registered-windows-agent-channel.md) adds a planned explicit transport prerequisite. Real signed driver loading, byte transfer, endpoint-pinned authenticated health, Windows credential hosting, combined installer and user-session/service separation remain open.

Windows fixed-byte transport prerequisite (private development record omitted)
now passes 26 portable contract checks, 13 sanitized transfer cases and two
identical static ARM64 builds for both INFO and transfer evaluators. Actual
signed-driver byte transfer/cancellation/disconnect, TLS1.3 credentials,
service/user split, combined installer and verified desktop workflow remain open.

The matching host fixed-transfer evaluator passes real private Unix/WorkerIPC fixtures, while a fresh original no-OS selected runtime passes private agent-route publication and actual forced settlement. This closes a transport-location prerequisite only; Windows driver byte exchange and authenticated integration remain unverified. Evidence (private development record omitted).

Native Keychain qualification (private development record omitted) now classifies the current ad hoc executable’s add attempt as missingEntitlement without UI or fallback; storage remains unqualified. Native menu correction (private development record omitted) shows one View menu, retained fullscreen/library controls and disabled creation commands in a real isolated Liquid Glass assistant. Full release, guest desktop/input and accessibility gates stay open.

Recoverable stopped-VM Trash (private development record omitted) now has exact writer/identity/confirmation guard tests and one actual original no-OS same-volume system Trash/verified filesystem restore. Full native GUI, Finder Put Back, standard source-parent ACL compatibility, external volumes, older hosts and crash durability remain unqualified; Experimental status only.

Restrictive source-parent Trash qualification (private development record omitted) now passes exact ACL/mode/identity tests and one actual new original protected-parent system Trash/restore with unchanged ACL. It models Documents protection without claiming actual Documents authorization. Native modal/Finder, other volumes/hosts and fault durability remain open.

Windows Schannel token custody (private development record omitted)
passes fifteen strict and sanitized portable cases and independent source review.
Actual Windows certificate signing, TLS context and scoped peer checks, transport
and health remain open; this prerequisite does not promote Windows agent support.

The original Schannel evaluator (private development record omitted)
now passes two identical strict ARM64 static builds, exact native import checks
and source review. No Windows TLS execution occurred. Actual signing/refusal,
encrypted records, device transport, enrolled health and installer remain open.

Fixed-record custody (private development record omitted)
passes fifteen strict/sanitized portable cases and independent review. This
validates spans, modes and native-return custody using fixtures; native encrypted
records, post-handshake processing and general application-stream behavior remain
unverified.

Native Windows fixed-record adapter (private development record omitted)
passes deterministic static ARM64 builds and actual observation-function descriptor
fixtures. These do not execute SSPI or cryptography. Native certificate signing,
encrypted records, rehandshake, device transport and authenticated health remain.

Library networking shortcut (private development record omitted)
adds context/accessibility navigation to the existing Liquid Glass editor with
exact selection, owner/modal and cancellation guards. Ten networking and
twenty-two library/Trash regressions, review and isolated build pass; native
physical menu/sheet and VoiceOver acceptance remain open.

The same-window library networking SDK transition (private development record omitted)
now passes actual sheet attachment/dismissal, idle app exit and unused fixture
preservation. Controller actuation does not establish physical menu/button or
VoiceOver behavior; Windows and older-host checks remain open.

Destination capacity (private development record omitted) now gives
both creation assistants a local host-space observation and separate sparse-disk
growth guidance, with the existing reserve recheck. 69 tests plus one explicit
native skip, isolated build and actual read-only CLI pass; no capacity reservation,
installation fit or physical assistant UI claim follows.

Raw row decoding (private development record omitted) now removes redundant
copies/calculations with unchanged bounds and snapshot behavior. Correctness,
sanitized parser tests and generated-frame release before/after evidence pass;
native frame pacing, input latency, Windows Retina and guest graphics remain open.


13 October user follow-up: top controls/capture evidence (private development record omitted)
adds persistent same-VM capture preference, foreground recapture, stale queued-input
refusal and permanent native lifecycle/display toolbar. Actual optimized handoff
and focused checks pass; physical switching/fullscreen and native Windows resolution/
FPS remain open. Human sign-in remains unfinished and input belongs to the human.

13 October GPU priority: native DXMT passes 145 hardware D3D11 checks, and Neptune
passes seven transport initialization/capability checks. The matching GPU QEMU
build succeeds, but its virt-10.0 machine cannot replace the saved VM's virt-11.1
contract. Native Metal display dependency build and compatible runtime integration
continue. Windows acceleration, native-resolution FPS and input soak remain open.
See exact GPU prerequisite evidence (private development record omitted).

13 October continuation: explicit GPU-trial toolbar console selection now has
13 focused App/capture/context checks and a verified immutable release build
(143 source pins, three outputs). The running d7 app has not been replaced.
RFB explicit full-refresh transport has18 synthetic checks; CLI observer has8
checks and bounded frame-wait/receive intervals. All remain experimental;
Windows driver install is at actual UAC awaiting action-time confirmation.
Actual native framebuffer, resize application, pointer alignment and FPS remain
open. Preserved signed-in VM/current owner retained, no forced recovery.

14 October graphics/menu follow-up: full live Windows3456×2168 GDI/CCD/RFB
agreement and ordinary4K60 mode application/restoration are verified. 120Hz
remains unverified; the signed Windows driver currently reports60Hz. The prior
0x119 invalid-fence bugcheck keeps long-running stability open. Candidate fence
isolation/accounting has narrow regression evidence. The corrected native
fullscreen policy now keeps the Apple menu visible on the current host through
entry, exit and re-entry; broader D5/Dock/older-host acceptance remains open.
Native input recapture has a synthesized app-switch/first-key check, with physical
keyboard and game-relative input still pending. C: now uses the120GiB disk with
the original recovery partition preserved, registered and actually booted; return
to Windows is verified. The synchronous simple shader completes55.8FPS, while
App39 display delivery measured28–29 updates/s. After the user authorized a
restart and continued control, App41 early RAW-header prefetch measured30.9/30.8
updates/s in two clean native-resolution trials. This is a modest observed change,
without a confidence interval or60/120Hz, game or physical scanout claim. See the
updated Windows GPU evidence and PERFORMANCE for exact scopes and remaining
graphics/game qualification.

14 October cursor follow-up: the user reports the host cursor intermittently
showing over the guest. A separate source41 build reasserts the scoped cursor on
mouse movement/drag/buttons/wheel/entry and tracking changes. Hidden-view cursor,
capture/fullscreen/viewport and decoder/client checks pass72 tests across six
suites; strict formatting and release packaging pass. Actual generated native
QEMU frames, forced refresh wire requests, immutable snapshots and clean child
cleanup also pass. The later authorized restart installed App41. Its native Input
menu reports capture; a synthesized app-switch/first-Windows–R sequence succeeds
without a Capture Input action. Physical cursor movement remains pending after
the native automation service rejected a coordinate action. No gaming or120Hz
status is promoted. See the current
cursor evidence (private development record omitted).

14 October GPU delivery follow-up: dedicated surface evidence (private development record omitted)
records native/4K generated export and actual separate-process consumption, with
every-pixel checks, five sanitizer fault cases and normal child reaping. A further
real native DXMT shared-source/fence experiment passes release and sanitizer
checks: exported pixels survive source overwrite. Both are components. Real
Windows producer ordering, admitted runtime/session surface transport, asynchronous
recovery, physical presentation and120Hz remain open under ADR43. The existing
App43 VM stays on its working RFB display; no status is promoted.

15 October continuation: actual input burst and overload recovery (private development record omitted)
passes the512-byte independent guest/host hash check, safe3000-character rejection
and first-key recapture after synthesized app switches. The fix uses a bounded
queue and preserves normal focus preference.23 targeted tests, strict release
packaging and preserved normal shutdown pass. App46 keeps the previous QEMU28
after its native comparison (private development record omitted) measures
53.4/52.4 draws/s; the unused RGBA experiment showed no live gain. Physical input,
cursor movement, long soak, games and120Hz remain open; no status promotion.

15 October graphics continuation: bounded native GPU timing (private development record omitted)
passes159 generated D3D11 checks in both variants, eight native/4K pixel/fence
cases,256-frame native streaming, concurrent numeric output bounds and generated
QEMU/HVF/ANGLE conformance with normal quit and actual reaps. The separate
App47 live trial now retains8448 completed records below the2MiB log limit, with
no malformed line/stop marker and normal guest/app exits. Broad Start/shader
brackets do not establish utilization or critical path. Receive borrowing (private development record omitted)
passes50 parser/socket tests, generated native/4K pixels and ASAN; paired component
feed times decrease. App48 restores timing-disabled QEMU28 and measures53.7/51.5
native draws/s; no clear guest FPS gain. Native fullscreen/menu, pointer clicks
and first-shortcut recapture pass narrowly. Sustained cursor, GPU-surface
transport, physical scanout, games and120Hz remain open; no status promotion.

14 October delivery follow-up: App42's borrowed RAW body path passes48 transport/
decoder tests, independent generated-frame hashes, actual diskless QEMU frames
and two clean native3456×2168 Windows delivery trials (51.6/50.5 AppKit draws/s).
The queued shader separately measured55.2FPS. Start-menu stalls remain; physical
pointer input cannot be qualified because desktop coordinate actions fail in both
native fullscreen and windowed presentation. The synthesized first-Windows–R
sequence and fullscreen exit/re-entry succeed after unlock.120Hz, physical scanout
and games remain open. Delivery evidence (private development record omitted)
and partial-readback candidate (private development record omitted)
record the next bounded copy optimization; the running App42 still uses runtime27.

15 October sound/capture continuation: [ADR52](adr/0052-windows-audio-playback.md)
records the inbox Windows HDA endpoint and App71/QEMU38's actual finite, unclipped
float32 stereo output. The user still reports missing or distorted sound, so useful
playback remains experimental. Native output is unmuted; channel/routing, Windows
endpoint and listening checks remain. Microphone forwarding is absent. App71
normally settles/reaps with no app left running. Control–Option–Escape releases
live Game Mouse capture; its menu action and shortcut are explicit, with physical
Escape recognized independently of its character string.
[ADR54](adr/0054-hidden-window-drawable-acquisition.md)
tracks a visibility gate that preserves GPU copies/ACKs while avoiding hidden
screen acquisition. Its actual native/4K GPU cache fixture and live Windows
startup/fullscreen/focus recovery pass. Controlled gameplay delivery remains
pending.120Hz and the remaining gameplay hitches stay open.

AFK graphics continuation: [ADR55](adr/0055-pipeline-task-object-lifetime.md)
qualifies bounded temporary-object lifetime in the actual compilation adapter
and builds a signed/interface-preserving native candidate, not yet installed.
[ADR56](adr/0056-windows-high-refresh-driver-trial.md) records the newly published
v0.4 driver timing path, verified publisher/catalog/CRL evidence and explicit
host120Hz source selection. The16October live60Hz trial fails; firmware-display
recovery verifies the installed signed package and original recovery settings,
then rollback restores the3456×2168 Windows desktop and those trial owners close.
[ADR57](adr/0057-graphics-protocol-pairing.md) identifies guest wire2 versus host1
and qualifies matching isolated sources with actual ABI/capset admission and
191 native D3D11 cases. App74 and the signed v0.4 package subsequently reach a
3456 × 2168 Windows desktop at 60 Hz with a healthy device and hardware D3D11
creation. First device binding reapplies the INF recovery overrides; live
readback catches them, and the reviewed restoration removes both before a normal
shutdown. The later high-refresh readback verifies original recovery defaults
after reboot and source/CCD target3456 ×2168 at120/1, with healthy hardware
D3D11 FL11.1 and matching CS2 settings. This applies the native120Hz mode;
persistence after reboot, sustained120FPS, game pacing and physical scanout
remain open. On resumption, normal runtime settlement and actual app-parent
exit/reap0 are independently confirmed. App75 presentation feedback remains
the next live gate under [ADR58](adr/0058-mac-presentation-feedback.md).


16 October presentation continuation: [ADR59](adr/0059-presentation-visibility-reconciliation.md)
records a dedicated AppKit Metal backing surface, MainActor layer geometry and
visibility reconciliation. App78's bounded native-fullscreen shader sample
reports105.8 Mac presentations/s with16.67ms worst presentation gap, below120FPS.
An off-Space reconnect diagnostic has2,157 zero timestamps despite active/key
flags. App79 adds active-Space admission/replay and passes27 app/six backend tests,
signed release and source provenance. After manual unlock, the native-viewport
full-display shader delivers107.1 Mac presentations/s, worst presentation
gap16.67ms, with active-Space/resume checks and a separate browser-chrome
fullscreen reconnect sample106.0/s. The shader buffer is3456×2169 atDPR3;
exact native height is unqualified. VM and actual App79 parent close normally,
with QEMU/TPM exit0, drained/flushed/revalidated settled state and parent reap0.
No sustained120FPS, game, physical scanout, audio or production-readiness claim.
