# 65. One guest-tools installer for the selected Windows runtime

Status: preview implemented; native qualification in progress. See
[verification evidence](../evidence/guest-tools-2026-11-16.md).

Users should not identify INF files or install networking and graphics separately.
Provide an **Install Guest Tools** entry in macOpenVM and a native Windows installer
on the selected read-only tools disc. The installer handles all matching devices
in one operation, requests normal Windows elevation, and reports each outcome.
Windows AutoPlay offers the installer; opening the disc remains a fallback. Do not
type hidden shell commands or bypass Windows' execution or signature policies.

The host selects a pinned basic, 2D or accelerated tools disc. Only the accelerated
disc contains the unmodified Neptune v0.4 package paired with the existing wire-2
host. Never install both competing graphics packages. Existing saved discs remain
admitted. Media changes retain the ordinary stopped-VM admission and ownership.
Networking and graphics settings are separate explicit choices, not side effects
of attaching tools. The installer installs only packages with present matching
hardware, and never forces a lower-ranked driver or restarts Windows automatically.

Before any installation, verify the complete packaged payload against compiled
hashes. Use Windows' driver installer and retain its signature enforcement. Query
device health separately from package processing. Missing devices, processing
failure, healthy devices and restart-required results must remain distinct.
Every graphics profile requires a visible GPU; its absence is incomplete setup,
never a successful optional-driver skip. Firmware setup display selection remains
available until the Windows GPU driver is working.
For Neptune, preserve and immediately restore the two upstream global graphics
recovery overrides on every installer outcome. Refuse unknown value types and
retain a durable recovery record before the driver call. No persistent installer
service, guest-agent enrollment or credential is created.

Acceptance: reproducible ARM64 executable build; pinned package/ISO readback;
failure before mutation for changed/missing payload; correct matching and result
classification; Windows UI remains responsive; no forced restart; normal UAC;
graphics settings restored; matching live network and graphics devices tested;
existing media admission regressions and release build pass. Distribution must
retain the upstream notices and source references. Public binaries remain preview
artifacts until signing, clean-machine and accessibility release gates pass.
