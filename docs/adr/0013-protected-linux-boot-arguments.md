# ADR 13: protected stopped Linux boot-argument changes

Status: experimental with named-host metadata qualification (private development record omitted).

The paired image selection extension (private development record omitted)
adds kernel and initramfs URLs together with arguments in the same atomic
registration replacement. It changes three existing string tokens only and checks
both readable bounded regular images. Readability does not establish version,
architecture, authenticity or a matching generated initramfs.

An installed Linux root requires an explicit stopped transition from live-media
arguments to its observed disk root. Detaching an ISO alone cannot make this
transition. Expose a Linux/direct-kernel-only Core and CLI operation; it does not
install an OS, change the kernel/initramfs selection, or verify a root identifier.

Acquire a fresh matching writer lease after bounded strict registration inspection,
reread under ownership, and validate host/settings. Change only the kernelArguments
JSON token, preserving all other bytes. Preserve an exclusive exact original
configuration backup before an anchored atomic replacement, file/directory flush
and exact readback. One-file configuration replacement needs no multi-file disk
growth intent: no disk bytes or identity files are modified.

Storage independently checks the exact token transform and current bytes, and
reserves the owner for metadata only. A prior inherited lease, runtime/growth
reservation, recovery-purpose lease, unsettled runtime or pending growth rejects
the operation. An attempted failure freezes that owner. Preserve backups and actual
state after uncertain rename/flush; do not retry or roll back automatically.

Acceptance includes escaped keys/BOM/format preservation, seeded disk and platform
identity preservation, active/pending owner rejection, ambiguous/unsafe inputs,
backup collision, cancellation and before/after-rename faults. CLI trials use only
fresh fixtures. Actual installed-root/EFI/GUI boot and minimum-host behavior remain
separate gates. Windows boot settings use their own verified platform path.
