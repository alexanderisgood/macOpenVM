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
| A1 | VoiceOver library/assistant/settings/errors, keyboard-only workflows, high contrast/light-dark/reduced motion/Reduce Transparency; native Liquid Glass on 26+ and equivalent 14–25 fallback; audit on each supported host |
| G1 | Guest renderer/API correctness plus separate render/transport/presentation timings, median/p95 input and frame stalls at applied native mode |

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
