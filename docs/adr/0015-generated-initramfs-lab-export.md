# ADR 15: retain generated boot archives through an owned lab disk

Status: accepted for the disposable integration fixture; no product disk format
or installation workflow is introduced.

The qualified Linux root exists in temporary memory. A generated boot archive
must survive guest shutdown so an independent host reader can verify its complete
gzip/newc bytes. Serial transcripts are bounded and the support drive is read
only. Streaming a large archive through that console would consume the diagnostic
budget and complicate ownership of the result.

The generation trial may copy only the observed archive bytes to offset zero of
its newly created, initially blank 8 GiB system disk. That disk is an explicit lab
transport in this mode. It is unmounted, receives no partition or filesystem, and
contains no user data. Other fixtures and registered VMs remain untouched. Record
the intended change as `exportDiskUsed`, with `blankTargetPreserved` false;
`persistentInstallationPerformed` remains false.

Before copying, recheck the guest device role, size and unmounted state. Record
actual writer status, byte count, archive hash and flush result separately from
generation success. Do not reuse the disk after a failed or interrupted trial.
After normal guest shutdown, terminal process/drain closure, stopped history and
an independently available lease, read the same host raw inode using a bounded,
read-only descriptor. Preserve device/inode, owner, mode, links and capacity;
allow allocation and content timestamps to change for the intended copy.

Retain exactly the reported bytes in a new exclusive fixed-name file, compare
their hash with the guest observation, then inspect gzip/newc framing and archive
closure without extracting or executing members. Unknown copy/flush/shutdown
observations cannot establish a retained result. Generator zero does not prove
archive completeness, and archive verification does not prove a successful boot.

Acceptance: exact owned-device binding and bounded copy, complete observations
and durable retained bytes, independent format/input/module checks, unchanged
registration/source/media/live state, and truthful separate failure outcomes.
Actual kernel/archive cold boot follows these checks. Public distribution and
corresponding-source review remain separate.
