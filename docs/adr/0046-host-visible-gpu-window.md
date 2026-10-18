# 46. Bounded host-visible graphics mapping capacity

Status: live Windows memory reporting verified; performance benefit pending.

The native Windows/CS2 trial still has recurring delivery pauses on both the
shared and standard display paths. The host presenter handles arriving frames
quickly, and App52's VM-lifetime activity token prevents App Nap without resolving
the pauses. Windows also restarted inside the same QEMU run; its event log
records0x119/subtype1 invalid-fence-ID crashes. The exact defect and any link to
the recurring pauses remain unproven. Memory exhaustion has not been established.

The existing accelerated launch hard-codes QEMU's public `hostmem=1G` property.
The reviewed QEMU source exposes this as a 64-bit prefetchable PCI BAR and
host-visible shared-memory capability. Its backing is an anonymous mapping,
not an up-front reservation of dedicated physical GPU memory. The signed guest
driver reports the discovered shared-memory length as its CPU-visible segment's
size and commit limit; it separately fixes the CPU-invisible aperture at1GiB.
Increasing the host-visible window therefore does not remove every1GiB limit.

Add an explicit runtime-only selection of1GiB or4GiB to the reviewed accelerated
profile. Retain1GiB as the API/standalone-worker default, and select4GiB for the
private GUI graphics trial. Carry that selection explicitly to the owned worker;
stored VM metadata cannot enable it or supply an arbitrary device argument.
Both the combined and separate firmware variants use the same closed selection.
The current driver's64-bit segment lengths/base and page-count allocator can
represent4GiB; its bitmap requires128KiB. Real Windows boot/device/memory
reporting remains an acceptance check, not an inference from these types.

This trial leaves the signed driver, enforcement, renderer/library/QEMU hashes,
guest RAM, vCPUs, disk, TPM and firmware identity unchanged. A normal stopped
session is required before replacing the app and starting the changed device.
Rollback selects1GiB and restarts normally. A larger window may allow more mapped
resources and increase physical memory use; it does not promise faster rendering,
4GiB of dedicated VRAM,120Hz modes or120 fresh frames/s.

Acceptance requires real Windows native3456×2168 boot, working input, device
health and reported memory, followed by the same offline CS2 scene and bounded
frame-delivery measurement. Retain the result even if pauses or crashes remain;
do not promote the setting based only on successful launch-argument tests.

The57 trial shut down52 normally, installed after native Quit/actual reap, and
booted the same Windows disk/TPM/firmware at3456×2168. Task Manager reports4GiB
dedicated and12GiB shared GPU memory. This meets the narrow boot/reporting check;
CS2 pacing, crash-free stability and physical120Hz presentation remain open.
