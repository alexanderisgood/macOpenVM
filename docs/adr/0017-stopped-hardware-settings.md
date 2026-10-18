# ADR 17 — Stopped CPU and memory settings

Status: implemented and experimentally verified for metadata/CLI and actual Linux next-boot resource application; native UI and Windows guest resource evidence pending.

CPU and memory already participate in backend-neutral configuration validation and
native launch. Expose their existing behavior through a settings sheet and a
matching CLI operation instead of requiring users to edit registration files.
Windows configuration must retain its stricter minimum resources; this editor
must not imply that its runtime or installation path is release-qualified.

Save requires the actual matching writer lock, no unresolved runtime or disk-growth
intent, current configuration equal to the settings snapshot, and valid host/guest
resource bounds. Replace only the two numeric JSON tokens, preserve every other
byte, write an exclusive durable backup, atomically replace and verify readback.
Identity, EFI/TPM state, disks, media, network and credentials are outside the
operation. Cancellation before replacement retains registration and any backup;
an error after rename reports uncertainty and never rolls back automatically.

The Liquid Glass sheet is available only for an idle selected VM. While it is
open, starting or replacing that selection is disabled. Values apply at next
start; saving does not start the VM. A failed save keeps the draft and provides
recovery text. Any changed on-disk registration invalidates stale app selection.

Acceptance: actual file-preservation and stale/active/pending/fault tests, shared
Windows/Linux validation, strict app/CLI build, actual signed CLI save/reject/no-op
checks on fresh fixtures, and native sheet/save/next-boot observations. Keep the
live Ubuntu trial and current app bundle untouched during implementation.
