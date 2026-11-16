# Verification procedures

Record exact host/guest/backend/app/agent/driver versions, actual outcomes and
redacted raw evidence. Missing media/hardware/entitlement cases SKIP with reasons,
never silently pass. Tests/mock backends do not establish guest integration.

| ID | Manual/automated acceptance procedure |
|---|---|
| B1 | Boot real ARM64 Linux, capture guest kernel/version/console, interact with display and input, clean shutdown; repeat with persistent disk/EFI identity |
| B2 | Install lawful Windows ARM64 on compliant EFI/Secure Boot/TPM; show native drivers and actual desktop; no security/driver-check bypass |
| L1 | 100 real start/pause/resume/clean-stop cycles; forced-app/backend exit, stale runtime state, restart; verify disk contents and ownership |
| S1 | Two processes attempt writer lock; abrupt lock-owner exit; out-of-space/permission failures; interrupted metadata commit; preserve old bytes |
| N1 | Explicit NAT DHCP/DNS/outbound/connectivity; stable MAC; confirm no inbound LAN exposure; offline has no adapter; conflict forwarding |
| D1 | Discover every screen/viewport/backing scale; compare requested/applied guest mode/framebuffer dimensions at native resolution and explicit lower mode |
| D2 | Resize storms, stale replies, bounded retries; reconnect, sleep/wake, driver restart, fullscreen and monitor changes; no oscillation; aligned pointer |
| D3 | Click grid/corners/letterbox, drag, scroll/right-click; exactly one cursor; capture release, focus failure, exit; external display and relative games |
| D4 | Physical and synthesized repeated digits/held keys/modifiers/UK-US/Command-Windows/shortcuts/IME; focus loss/disconnect releases all keys; correct target |
| D5 | Fullscreen keeps real menu bar, native aspect/density, entire taskbar; no library/toolbar/banner/sidebar; Dock absent; normal presentation restored |
| D6 | Repeated fullscreen, focus/activation, borderless/transient detach, modal dialogs, sleep/wake and failure; same owning/key window/frame/style |
| D7 | Start hides library; menu/shortcut deliberately reopen; context actions only where backend supports; confirmed deletion preserves unrelated data |
| D8 | One support drive contains one tool for lawful agent/native drivers with attribution; no second third-party setup drive |
| D9 | Run Setup reaches installer in Windows; explicit elevation/progress/errors/manual fallback; authenticated version and component health hides banner |
| D10 | Keychain absent/locked/denied does not reset it, weaken pairing or block unrelated boot; no repeat Mac password or credentials in files/media/logs |
| D11 | Windows setup guide is reachable from creation, selected VM and Help while running; show configured offline/shared and attached/detached states without claiming driver health; exact guest driver folder and public download are visible; opening/closing help preserves configuration and runtime; verify scrolling, keyboard access and small-window layout |
| A1 | VoiceOver library/assistant/settings/errors, keyboard-only workflows, high contrast/light-dark/reduced motion/Reduce Transparency; native Liquid Glass on 26+ and equivalent 14–25 fallback; audit on each supported host |
| G1 | Guest renderer/API correctness plus separate render/transport/presentation timings, median/p95 input and frame stalls at applied native mode |
| W1 | Windows app/CLI recommendations agree; cover 8–128 GiB host capacities, explicit overrides and rejected insufficient resources; recommendation changes only a draft until save/create |
| G2 | Shared display copies preserve visible pixels for padded odd widths, 1080p, native and 4K buffers; reuse both producer slots, preserve read-only mappings and acknowledge only after GPU completion; report generated copy timings separately from G1 |
| G3 | Bind a nonzero constant-buffer range, then rebind the same buffer through the legacy API and through null offset/count arrays. Verify reset offsets and actual red/green pixels in immediate and deferred contexts. Keep the range-only control and shared-alpha/native graphics suites passing. Windows missing-text verification remains a separate live check |
| G4 | With a Windows GPU display active or disconnected, enable Compatibility Display and verify a fresh frame and responsive input on the standard display. Reconnect again and verify the choice persists. Toggle it off to resume the admitted Metal display. Confirm the worker session, guest driver and display geometry are unchanged |
| S2 | macOS Windows storage avoids synchronous ordinary writes while preserving guest flush/FUA, sparse raw storage, discard and read-only media; alternate disposable QEMU cache-mode trials with final flush included and reopened byte verification; separately qualify Windows latency after a normal launch |
| S3 | New Windows app/CLI defaults use the same sparse capacity; overrides preserve minimum/resource admission. Guest Tools storage opt-out performs no commands, preserves selection across elevation, verifies hibernation-file removal, distinguishes command/verification/retrim failures, and never claims host bytes reclaimed without measurement; verify native repeat-run, Windows free space and recovery |

Unit/contract tests must include invalid transition/resource/schema/path cases,
round trips, cancellation and stale completion, storage faults and bounded imports.
Protocol fuzz/conformance runs both host and native guest decoders. Snapshot support
requires restored guest data after power-loss/disk-full/corruption campaigns.

The bounded metadata corpus in Tests/CoreTests/MetadataFuzzTests.swift has a fixed
seed, 12,000 inputs, exact byte boundaries and recorded-stop consistency cases. Its
scope excludes imported OS/disk parsers, protocol traffic and diagnostic archives.
See evidence/metadata-fuzz-2026-10-06.md; it does not close the security gate.

Before B2, a separate ARM firmware/TPM probe must reject unsigned and revoked EFI
images, authenticate variable updates, verify current PK/KEK/db/dbx provisioning,
retain TPM identity across restart/crash and document the actual HVF path. Never
replace a failing security requirement with disabled checks or emulation fallback.
Current firmware/device recipes remain candidates, not a compliant Windows boot.

The initial original EFI/TCG2/public-command probe now passes under HVF/native
GICv3 on the named macOS27 host; see firmware evidence (private development record omitted).
It reports SetupMode1/SecureBoot0 and cannot satisfy B2.

The next NV subtest uses a newly created owned fixture, ordinary owner index
0x01804D56, SHA256 Name and a32-byte public random fixture nonce. Prepare must
reject any successful initial ReadPublic as a collision before writing, accept
only the exact missing-index reply, then define/write/validate/read back.
Verify is separately compiled with definition/write code excluded and issues
only ReadPublic/Read. Both validate exact big-endian response lengths, session
structure and NV public/Name/data. Hold the lifetime writer lock across both
process pairs; acknowledge QMP quit, await both children and hash saved state
before the second launch. Use the same variable/TPM stores without resets,
replacement or cleanup. Readback after orderly restart is narrower than the
separate scoped-crash persistence requirement; firmware startup may change
other TPM state. Never require a whole-store byte match after boot two or repair
missing data to make the test pass. Preserve all failures/stores and emit no raw
nonce, passwords, user paths or guest content into public results.

Executed narrow native procedures are in evidence/linux-native-2026-10-06.md,
evidence/storage-and-build-2026-10-06.md and
evidence/linux-network-and-serial-2026-10-06.md. The explicit serial/NAT contract
is Tests/Integration/native_serial.py; it is not a silent substitute for all N1/D4.
# Guest tools installer acceptance

GT1: one visible Mac entry prepares the matching disc through stopped media admission.
GT2: all payload hashes pass before driver mutation; mismatches and missing files fail closed.
GT3: install only present matching devices; show package result and device health separately.
GT4: keep Windows signature enforcement, restore graphics recovery settings, never force restart.
GT5: exercise native ARM64 installer, network and accelerated graphics, and existing media regressions.
