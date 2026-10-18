# ADR 11: original NVMe storage prerequisite

Status: experimental prerequisite with a passed original two-boot persistence trial. Windows installation,
inbox-driver loading, power-loss integrity and release acceptance remain open.

The initial Windows storage investigation uses the public NVMe controller path.
Microsoft supplies StorNVMe; this reduces the initial dependence on an unqualified
third-party storage driver. It does not establish that the intended ARM64 installer
discovers this particular virtual controller. The retained EDK2 firmware includes
NvmExpressDxe, and the qualified QEMU 11.1 build includes its NVMe controller.

Before attempting an accepted Windows installer, verify an original no-OS storage
slice on a newly created, disposable 32 MiB raw namespace. Select it by explicit
NSID/EUI64 bytes and exact geometry rather than capacity alone. Attach no user disk,
network or OS media. Keep existing firmware, security state and runtime profiles
unchanged; the separate lab runner owns one QEMU process and an inherited writer
lease rather than weakening the existing TPM-pair backend contract.

An original prepare EFI module writes three nonce/LBA-dependent sectors after
confirming their zero contents, flushes, then compares readback. An independently
compiled verification module excludes all mutation calls. The host scans the
entire raw file after actual process exit and completed drains, then performs a
new-process verification boot while retaining the same writer lock. It requires
the same file identity and full hash after that boot. Only the three specified
sectors may differ from zero.

Acceptance requires bounded namespace/path/handle/alignment validation, exact
original observation rows, qualified payload/firmware hashes, actual QMP quit,
reaping and drains, inherited-lease exclusion, whole-file verification and
preservation of all failures. This proves only scoped orderly persistence through
the firmware NVMe path. It does not qualify Windows StorNVMe, production snapshots,
host power loss or a recovered worker after a crash.

References: [QEMU 11.1 NVMe](https://raw.githubusercontent.com/qemu/qemu/v11.1.0/docs/system/devices/nvme.rst),
[Microsoft StorNVMe](https://learn.microsoft.com/en-us/windows-hardware/drivers/storage/nvme-features-supported-by-stornvme),
[UEFI Block I/O](https://uefi.org/specs/UEFI/2.11/13_Protocols_Media_Access.html#block-i-o-protocol).


The native evidence (private development record omitted) passed on
the named development host. Retain the failed first fixture: PlatformBootManagerLibLight
connected only devices listed by QEMU's firmware boot order. Giving the namespace
explicit bootindex2, behind the EFI drive's1, exposed its BlockIO subtree without
changing firmware or weakening identity checks. The corrected fresh trial completed
both phases, whole-file verification and actual owned cleanup. The same-mode
verification process preserved disk identity, hash and modification/change times.
