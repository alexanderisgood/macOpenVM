# ADR 14: one separate read-only support image

Status: implemented and narrowly qualified, 2026-10-07; see
tests and fresh passive Linux delivery (private development record omitted).
Windows remains the primary target and its setup workflow remains gated.

## Decision

Add one optional `supportMedia` local path to the version-1 desired configuration.
It represents a data image separate from the operating-system installation image
and writable system disk. It is always read-only to the guest. It does not supply
boot media, authenticate contents, install an agent or establish guest readiness.
Existing configurations omit it and continue to decode on the new application;
older application versions are not promised to understand the new field.

The first exposure is an explicit CLI creation option for a fresh directory. The
existing creation transaction inspects the optional input before creating files
and retains the established disk/identity/registration commit order and writer
ownership. No support-media attachment, detachment, replacement or GUI setup
button is enabled by this slice. A future stopped replacement requires its own
protected transaction and evidence.

Use the public AppleVz storage-device array in this order: writable system virtio
block device, existing read-only installation USB mass-storage device when supplied,
then one read-only support USB mass-storage device. This is data-image delivery;
the device is not represented as an optical drive. The evaluated Linux QEMU plan
maps the same optional role to a distinct read-only USB storage attachment. Its
Windows gate stays closed. Public API availability and a constructed device array
do not establish actual guest delivery, Windows driver health or macOS 14 runtime.

## Input, metadata and diagnostics

The support path must be a bounded local absolute path. Creation requires a
readable, nonempty, regular image with 512-byte alignment and refuses a symlink.
Checks do not hash/authenticate image contents or retain its identity for an entire
future VM runtime. Read-only attachment protects against guest writes; it does not
make a hostile image safe or prevent another authorized host process modifying it.
No source file permission, global trust store or host preference is changed.

Both strict configuration readers must accept the optional string field. Surgical
boot/media/growth updates preserve its exact serialized bytes, and completed
growth continues to bind only its existing critical disk/identity fields. The
read-only doctor reports the support role without acquiring a writer or executing
its contents. The field must never be silently ignored by a selected backend.

## Acceptance

Verify legacy configuration behavior, rejection before destination creation,
readability/type/alignment and bounded paths, distinct persisted roles, strict
duplicate/type handling, unchanged boot/media/growth bytes and ownership gates.
Inspect the actual Apple storage attachment order/read-only flags and the QEMU
argument mapping. Then use one fresh offline guest to verify the second image's
read-only device and mounted contents against a pinned manifest, followed by
observed guest poweroff and actual owner exit/stream/resource closure.

The first carrier contains private verified Alpine inputs, signed repository
metadata and a hash/license/source manifest. It is an installation-test
prerequisite. Package solver/application, matching generated kernel/initramfs,
persistent Linux installation and the combined signed Windows agent/driver setup
tool all retain separate acceptance gates. No third-party binaries are published.

## Stopped selection update

The stopped CLI selection trial (private development record omitted)
now qualifies support attachment and removal through the protected media transaction.
Use the saved expected VM identity, cooperating writer admission, bounded read-only
image inspection and an exclusive exact configuration backup with its separate
support-media prefix. Confirm backup and committed replacement readback before
success; preserve uncertain outcomes without automatic rollback. No-op preserves
the original bytes. The installer role and its existing API remain separate.
This adds no setup execution or GUI setting, and does not establish Windows delivery.
