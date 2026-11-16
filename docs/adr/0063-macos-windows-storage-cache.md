# 63. Avoid synchronous ordinary Windows writes on macOS

Status: implemented in source with disposable block-path verification; the
running Windows installer is not changed or restarted.

The registered Windows plan uses `cache=none`. QEMU's POSIX backend maps its
direct-I/O flag to `O_DSYNC` on hosts without `O_DIRECT`, including macOS. The
live Windows system-disk descriptor was independently observed with `DSYN`.
During a 20-second installer observation, the QEMU process read 1.96 MiB/s and
wrote 2.23 MiB/s while using roughly 6–7% of one CPU core. This identifies an
avoidable per-write synchronization mechanism; it does not isolate all installer
delays or prove the size of a future guest improvement.

Use buffered writeback for the registered Windows system disk, explicitly retain
guest flushes, and retain sparse raw storage and guest discard. The NVMe device
continues reporting its volatile write cache; its flush and Force Unit Access
commands remain connected to QEMU's block flush path. No unsafe caching,
`cache.no-flush=on`, snapshot overlay or guest driver change is introduced.
Ordinary writes can complete in the host cache; guest durability requests still
wait for the host filesystem flush. This is not a power-loss qualification.

Acceptance: generated offline/shared plans preserve the exact cache and discard
options and literal paths; firmware and installer media remain read-only. A
small disposable QEMU block fixture alternates old and new cache modes, includes
the final flush in measured time, reopens and verifies all bytes, and checks FUA.
Retain all trials and distinguish this host fixture from a Windows workload.
Do not benchmark, reopen for writing, or modify the active user disk. Installation
time and Windows disk latency require a later ordinary guest launch.

The [bounded fixture](../../Benchmarks/STORAGE.md) passed reopened-byte and FUA
checks for all six trials. Median throughput including the final flush increased
from 104.13 to 246.37 MiB/s for this 16 MiB component workload. The exact pinned
app runtime independently accepted the proposed flags and opened its disposable
file without `DSYN`. Short trials and uncontrolled host load limit this evidence;
the result is not a Windows speedup or native-throughput claim.

Memory is a separate measurement. The host reported elevated memory pressure,
active compression and about 3.8 GiB of existing swap. The sampled interval had
no new swap-outs. Those observations do not justify increasing the VM's RAM,
changing it live, disabling compression or claiming native memory performance.
