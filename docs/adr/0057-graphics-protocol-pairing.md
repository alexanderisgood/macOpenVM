# 57. Pair the graphics wire protocol and backend contract before guest adoption

Status: isolated native pair built and signed; actual ABI1/capset2 check and
191 offscreen D3D11 cases and actual app loader admission pass. The paired
Windows driver boots a native-resolution desktop and subsequently applies
3456 × 2168 at120/1. Sustained120FPS and game performance remain unqualified.

The16October signed Windows v0.4 trial fails against the current Neptune host
even at60Hz. Firmware-only recovery confirms installation and restoration of
the original graphics recovery settings, then rollback restores the native
desktop. Preserve that working runtime while preparing its replacement.

The exact official ARM64 UMD contains the wire-mismatch diagnostic. Read-only
PE/ARM64 inspection follows its string reference to a load of the returned
version, `cmp w19, #2` at virtual address0x1800c164c, and the mismatch diagnostic's
guest-version argument2. The current renderer's generated header defines wire
version1 and its capset fill routine publishes that value. This independently
sufficient mismatch must be resolved; the guest's runtime diagnostic was not
captured, so it does not establish that no other incompatibility exists.

The upstream [protocol2 commit](https://github.com/utmapp/virglrenderer/commit/c0d8007c0f71cfba1b39dfcb73b06e575d41d7c8)
changes resource-update context routing, fence-arm ownership, command bounds and
canonical COM-object replies. Port the corresponding implementation and
generated headers together. Do not change just a capability integer or bypass
either peer's version refusal.

Prepare a separate host source at451505ad0aa449290f2c0672da6877d57ee770e5 and
Metal backend at66e27f3759ff79e41a791ec40e2a70ef6d0c964c. Both pin the same
[directx-native contract](https://github.com/osy/directx-native/tree/7258be1c56cdbf1e55c56b1bc4a866169c8ca0da),
versioned ABI1. Preserve its Apache-2.0 notices and review the shared-memory and
event implementation. The host must refuse a missing/mismatched native backend
ABI. It must continue to report only supported graphics features; DXMT does not
provide D3D12 or DXIL merely because the protocol can carry them.

Carry the current fixed native loader, completion-thread pool and constant GUID
initialization into the isolated sources. Replace the old local staging-upload
implementation with upstream's corresponding change and retain the existing
native conformance cases. Keep ADR55's pipeline-task pool separate. Preserve all
working libraries, QEMU bytes, support discs and platform/disk state; do not
overwrite the active runtime to prepare or test the candidate.

Before another driver adoption, require actual backend ABI1 and host capset2,
bounded command rejection, native renderer/conformance checks and a full loader
closure. Stage migration bytes while the working GPU is available; use the
firmware-only display for the Windows package transition so an incompatible
live GPU reset cannot strand the updater. Require signature/device/settings
readback, exact package hashes and a tested rollback route. Then verify native
pixels and60Hz first, followed by the separate120Hz selection and sustained
delivery. Match CS2's internal resolution independently. A source change or
advertised mode is not proof of120FPS or physical scanout.

The isolated source builds finish with actual parents retained/reaped: Metal
backend34.05seconds, installation11.94seconds, host7.61seconds. The first host
configuration lacks the previously reviewed local YAML module; its failure is
preserved, and a retry with that existing build dependency succeeds. Generated
unused-parameter and deployment-target warnings remain; no warning-free or
macOS14 qualification is claimed.

The host/server/backend are signed and frozen in a separate prefix. A QEMU38
copy is rebound only to the new renderer's absolute Mach-O dependency, then
re-signed with the original Hypervisor entitlement; QEMU source and VM
settings are unchanged. The actual public loader probe returns backendABI1,
hostWire2, capsetSize60, caps0xb6, and no D3D12/DXIL claims. The native D3D11
suite reports191 passes/zero failures, including the retained regressions and
new upstream buffer/query cases. All actual check parents exit/reap0.

App74 source admits that complete paired closure and v8 carrier together;
the protocol1/v7 carrier is refused by this new private profile. The frozen
App73 and complete old runtime remain available for migration/rollback.
These are component results; no new Windows driver adoption, applied120Hz,
CS2 performance or physical presentation result follows from them.

The subsequent firmware-display migration installs the signed v0.4 package as
`oem6.inf`, retains the exact staged v0.3 rollback package and normally removes
`oem5.inf`. The updater restores the original unset recovery overrides; separate
readback confirms their absence. Windows then shuts down normally and the actual
App73 parent exits/reaps zero before App74 replaces it under the stable app ID.

With the matching pair, Windows reaches its desktop at 3456 × 2168. The active
SYS hash matches the reviewed v0.4 package; the display device reports OK and
configuration error zero. Hardware D3D11 device creation succeeds at feature
level 11.1 on the same rendering and display adapter. Windows reports 60 Hz;
CCD target timing separately reports 3456 × 2160 at 60/1. This source/target
geometry difference remains explicit and does not establish physical scanout.

The new GPU device's first binding reapplies the INF's two global recovery
overrides despite their restoration around package staging. The live diagnostic
catches this before any performance run. The reviewed restoration tool removes
both known values, readback confirms absence, and Windows shuts down normally.
Require a second post-reboot readback before qualification; package-update
readback alone is insufficient when the device arrives later.

The first paired runtime settles with QEMU/TPM exit zero, no signals, drained
output and flushed platform state. Native Quit and the actual App74 parent reap
are recorded. A separately launched 120000 mHz trial reaches a 1280 × 1024 lock
screen. macOS locks during sign-in, so its applied Windows timing, recovery
settings after reboot, native-mode selection and CS2 delivery remain pending.
No 120 FPS result follows from booting or advertising the new mode.

Actual app admission catches an initial app-only entitlement on the QEMU copy
and the signature correction's changed byte count. Both failures are preserved;
neither configuration starts a guest. With the exact original Hypervisor
entitlement and actual signed byte/hash pin, native loader admission passes,
including carrier matching/refusal. Both CLI parser/command-gate regressions
also pass. Preserve those immutable bytes for the Windows transition.

The later App74 high-refresh readback verifies source and CCD target3456 ×2168,
GDI120Hz, CCD VSync/path120/1 and apply result0. Hardware D3D11 FL11.1 uses the
same render/display adapter; both original recovery overrides remain unset after
reboot. CS2 settings independently show3456 ×2168 at120Hz. This was a temporary
CCD application, so persistence after reboot remains unproven. A visible Nuke
spectator reading of approximately48FPS is uncontrolled. One app sample counts
zero received/drawn updates while a separate GPU view changes; later views
match, so a permanent transport failure or its cause is not established.

On resumption, the actual high-refresh app parent has exited/reaped0. Its runtime
result confirms normal QEMU/TPM exits, drained output, flushed platform state and
settled intent. The guest filesystem has not been independently checked. A fresh
process inventory and native app inventory show no remaining VM owner; the old
route must not be reused. Preserve frozen App74 and the paired graphics closure
while qualifying App75's separate Mac presentation observations under ADR58.
