# ADR 6: evaluate protected ARM64 firmware before Windows installation

Status: evaluation in progress, 2026-10-06. Pinned sources, host tools and firmware/probe builds (private development record omitted)
now passed in private fixtures. Initial original EFI/TCG2/public-command execution
and narrow NV restart/scoped-crash marker tests (private development record omitted)
passed. No runtime/dependency distribution adoption or key generation has occurred.
Legitimate public-test PK full-envelope and bare representations, followed by
positive PK/KEK/db readback and our own signed-image execution (private development record omitted),
also passed. Security enforcement and the Microsoft production trust chain remain
unverified; these successes do not establish a compliant Windows platform.
Actual PPI-on/HVF initialization failures and a paused mapping trace (private development record omitted)
now identify a QEMU host-memory-listener defect for a 1-KiB region. A private
narrow source correction was evaluated with PPI and HVF retained. Windows remains
blocked. See the prerequisite audit (private development record omitted)
for observed versions, content identifiers and tool availability.

The private source-built QEMU candidate preserves TPM PPI and uses only HVF. It
also backports the reviewed native-GIC Kconfig correction, with real GnuTLS PKCS#7
and read-only FAT support explicitly selected. Actual firmware execution reached
TPM 2 detection, then stopped because a mutable PEIM constructor wrote into
read-only XIP flash. The corrected candidate uses EDK2's existing PcdShadowPeimOnBoot
policy to relocate PEIMs into RAM before constructors; it does not change the
entropy implementation or make flash writable. A separate reviewed native-GIC
feature-advertisement fix then allowed GICv3 selection/countdown and the original
initial probe to complete. These results remain unprovisioned and do not establish
authenticated-variable/image/runtime enforcement or Windows boot/install.

## Problem and decision

The installed QEMU AArch64 firmware is a useful EFI starting point, but its
upstream build does not enable Secure Boot. Merely adding swtpm or enabling image
verification cannot establish protected authenticated variables, current trust/
revocation data, measured boot, or Windows driver health. A writable variable
pflash bank also needs a demonstrated protection boundary against guest software.

Evaluate QEMU's documented host UEFI-variable service with a separately pinned,
source-built AArch64 EDK2 candidate. Use open EFI payloads to prove both valid and
invalid authenticated updates and TPM persistence before requiring Windows media
or installation rights. This selects an investigation; it does not select a
redistributable runtime, establish Windows compliance or change the macOS 14 floor.

The source distinction is essential:

| Source | Observed configuration | Consequence |
|---|---|---|
| QEMU v11.1.0 `roms/edk2`, commit `4dfdca63a93497203f197ec98ba20e2327e4afe4` | ArmVirt platform has Secure Boot/TPM build switches but no `QEMU_PV_VARS` path. QEMU's common options enable TPM2; AArch64 does not receive the x86 Secure Boot option group. | This older firmware source cannot simply be configured into the newer host-variable candidate. |
| EDK2 `edk2-stable202608`, commit `2970e5699ba6267f3384ffab20f96647578aebc8` | ArmVirt declares `QEMU_PV_VARS`, `SECURE_BOOT_ENABLE`, `TPM2_ENABLE` and `TPM2_CONFIG_ENABLE`, default false. | Candidate flags must be explicit, and exact submodules/toolchain/licenses need review. |
| QEMU v11.1.0 host variable service | `uefi-vars-sysbus`; authenticated PKCS#7 implementation is selected when GnuTLS is available, otherwise a write-protected stub is used. | Device presence or rejection of every write is insufficient; require a legitimate signed update to succeed. |

Primary sources: [QEMU EDK2 gitlink metadata](https://api.github.com/repos/qemu/qemu/contents/roms/edk2?ref=v11.1.0),
[QEMU build options](https://raw.githubusercontent.com/qemu/qemu/v11.1.0/roms/edk2-build.config),
[older ArmVirt platform](https://raw.githubusercontent.com/tianocore/edk2/4dfdca63a93497203f197ec98ba20e2327e4afe4/ArmVirtPkg/ArmVirtQemu.dsc),
[candidate ArmVirt platform](https://raw.githubusercontent.com/tianocore/edk2/2970e5699ba6267f3384ffab20f96647578aebc8/ArmVirtPkg/ArmVirtQemu.dsc),
[QEMU host-variable design](https://raw.githubusercontent.com/qemu/qemu/v11.1.0/docs/devel/uefi-vars.rst),
[crypto build selection](https://raw.githubusercontent.com/qemu/qemu/v11.1.0/hw/uefi/meson.build)
and [stub behavior](https://raw.githubusercontent.com/qemu/qemu/v11.1.0/hw/uefi/var-service-pkcs7-stub.c).
All were read on 2026-10-06.

## Smallest useful experiment

After source/toolchain acquisition and licensing review, build one original
AArch64 EFI controller and one small open EFI child payload. They run on a new,
explicitly disposable, offline QEMU/HVF fixture with readonly firmware and payload
media, no OS/system disk, an exclusive owner, a private Unix swtpm control socket
and newly created persistent variable/TPM stores. Specify HVF alone; an unavailable
accelerator is a failure/explicit skip, never a TCG fallback. Store bounded private
results and content hashes; leave variable/TPM stores intact after failures.

Use disposable fixture-only signing material. The preferred later mechanism input
is already-published EDK2 TestKey/TestCert, verified against the pinned Git objects;
no user secrets need be generated. Anyone can sign with this test identity. Exclude
it from production guest trust/release discs. Never reuse user pairing, TPM, Windows, release-signing
or Keychain material. A test trust hierarchy proves the mechanism only; it cannot
substitute for the Microsoft trust/revocation chain in a later Windows evaluation.
No keys have been generated for this proposal.

Consumer source review identified a PKCS7 wrapper detector comparing an envelope
tag against0x0A rather than standard0xA0. A normal full-envelope positive failed
before the one-byte correction, then fresh full-envelope and bare positives passed
after it; see the exact interoperability evidence (private development record omitted).
Native testing (private development record omitted) now
confirms that the original non-append comparison accepted equal timestamps; a
separate correction passed all eleven named KEK cases. Require standards-valid full-envelope and bare
SignedData positives, a newer valid wrong-signer packet, structurally valid
tampering, exact replay and older-time rejection with unchanged readback. PK is
also authorized for db updates, so PK cannot serve as db's wrong signer. Do not
weaken rejection gates or assume a bare-only result proves envelope compatibility.

The controller remains trusted while loading child variants through UEFI image
verification. It records actual status and a unique executed-child marker. Before
and after every variable attempt, compare value, attributes and timestamp; then
reboot and check persistence. Exercise runtime authorization after
`ExitBootServices` through supported runtime services, rather than checking only
boot-time menu behavior. Do not call boot-service-only protocols after exit.

| Acceptance case | Required evidence |
|---|---|
| Provisioned User Mode | Actual `SetupMode=0`, `SecureBoot=1`, expected PK/KEK/db/dbx values and a working protected-variable transport. A force flag/banner alone fails. |
| Valid update | A correctly signed, fresh non-append update succeeds and survives reboot with the expected value/attributes. This detects a reject-all crypto stub. |
| Wrong signer, altered payload/signature or missing authentication | Rejected; preceding variable content/attributes remain identical. |
| Replay/older time | Replaying an accepted non-append update or an older timestamp is rejected without replacement. Append-write semantics require separate specification-driven tests. |
| Bounds and malformed authentication header | Controlled rejection for truncated/overflowing length fields and storage/payload bounds; no host crash, unbounded log or partial variable replacement. |
| Runtime policy | Unauthorized PK/KEK/db/dbx and security-mode changes remain rejected after the boot-to-runtime transition. Policy setters cannot silently enable Custom Mode or weaken protection. |
| Child execution | Trusted signed child executes; unsigned, modified-after-signing and newly revoked child do not. Record verification status plus absence of the child's marker. Keep the controller outside the child revocation. |
| TPM2 presence/measurement | Real TCG2 capability and TPM2 command responses, active SHA-256 bank, bounded event log and selected PCR values consistent with log replay. Device-name/help output fails this gate. |
| Persistent TPM identity | Create a nonsecret marker in a test-owned NV index; read it after orderly restart and a scoped runner crash using the same stores. PCR resets and NV persistence are distinct observations. No TPM reset/clear/replacement to make recovery pass. |
| Missing component | Missing TPM/crypto/host-variable support or an unavailable firmware build must fail or explicitly skip with the prerequisite named. Never continue with weaker security. |

This first experiment does not need Windows, a guest filesystem, graphics drivers
or a production credential. It does need a real EFI build, real guest execution,
authentication controls and persistent stores. Actual initial TCG2/public-command
execution, a completed NV marker over orderly restart/scoped process crash, and
the positive portions of PK/KEK/db and own signed-child execution have passed.
No entire security-enforcement row is promoted by those partial positives.

## Current build gates and rejected shortcuts

The initial tool audit found that local LLVM 22.1.8 provides a compiler and object tools outside the default PATH.
The candidate's [CLANGDWARF AArch64 definitions](https://raw.githubusercontent.com/tianocore/edk2/2970e5699ba6267f3384ffab20f96647578aebc8/BaseTools/Conf/tools_def.template)
target Linux ELF and require LLD. LLD and a GNU AArch64 cross toolchain were not
found in the inspected locations at that point. Subsequent private, pinned
toolchain acquisition and actual BaseTools/firmware/module builds passed; their
recipes and license inventory are retained in the firmware evidence. This resolves
that development build gate, not clean-machine reproduction or distribution
closure. Do not run the GCC5 helper against Apple clang as though they were
equivalent, or replace the recorded cross toolchain with an unverified one.

Reject treating `-machine secure=on` as UEFI Secure Boot: it controls Arm Security
Extensions. Reject plain unprotected pflash, signature-check bypasses, test-signing
Windows drivers, automatic emulation fallback, another application's firmware,
or enrollment defaults as complete revocation provisioning.

For later Windows tests, [Microsoft's current key guidance](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/windows-secure-boot-key-creation-and-management-guidance?view=windows-11)
specifies the 2023 Windows CA/KEK and current dbx for 25H2+ preloaded devices.
EDK2's [default enrollment](https://raw.githubusercontent.com/tianocore/edk2/2970e5699ba6267f3384ffab20f96647578aebc8/OvmfPkg/EnrollDefaultKeys/EnrollDefaultKeys.c)
contains 2023 certificates but initializes dbx with `mSha256OfDevNull`; its success
message does not prove current Microsoft revocations. Obtain and verify applicable
public trust data and its rights separately.

## Consequences and open gates

Nine image enforcement cases (private development record omitted)
now verify setup controls, legitimate signed execution, unsigned/altered rejection
and selective Authenticode-hash dbx revocation in one fresh boot. Six complete
child execution witnesses and three denied loads were independently decoded.
The initial parser error and corrected evaluation are both retained. This closes
only the named image-loading slice; cold persistence, runtime authorization and
Microsoft trust remain open.

The native AUTH2 rejection experiment (private development record omitted)
reproduced equal-timestamp replay and replacement acceptance in the private
four-correction QEMU build. A separate fifth correction enforces strictly later
non-append timestamps. All eleven named boot-services KEK cases then passed,
including legitimate newer updates. The existing app/VNC candidate was preserved;
adoption requires its own requalification. Wrong signer, other policy variables,
append/deletion, restart/runtime and image/revocation coverage remain open.

The host-variable service adds host attack surface and crypto dependencies.
Authentication, bounds, persistence, symlink/ownership controls, denial-of-service,
crash durability and security review remain required. QEMU GPL obligations, selected
EDK2/submodule notices, swtpm/libtpms and all transitive licenses remain open; a
subprocess boundary or matching binary hash is not legal clearance.

After this experiment, separately verify actual Windows installation rights,
platform/ACPI/PPI behavior, minimum resources, boot and setup, ARM64 driver catalog
signatures and component health, display/input/applied resize, and the supported
host matrix. Open EFI or Linux success cannot satisfy any Windows workflow gate.

## Separate read-only measurement-consistency slice

An original controller and host decoder now implement a narrow public TCG2 log
and SHA-256 PCR consistency experiment. Their independent reviews, builds, pure
tests and first native run (private development record omitted) passed.
This is separate from the unverified
authentication enforcement cases above and performs no variable, NV, image-load,
key or OS operation.

The firmware pin and its reviewed allocation implementation establish a64KiB
main-log buffer. Before copying it, the controller also checks the whole aligned
span against a fresh readable BootServicesData/NVS memory descriptor. A descriptor
alone does not prove allocation ownership. Only owned copies are parsed; the last
pointer must identify an exact entry start. The final-event table is excluded.

Two public PCR_Read responses bracket two main-log snapshots. Counter, selected
PCR0/2/4/7 values, base/last pointers and used bytes must stay equal. The host
independently validates framing/algorithms/lengths, handles the supported initial
localities, skips no-action records and accumulates logged SHA-256 digests. A
changed, partial, malformed or unsupported snapshot fails rather than producing
consistency evidence. Real measurement authenticity, Microsoft policy, Windows
TPM health and the rest of the protected platform remain separate gates.
